# frozen_string_literal: true

# StevensED: requests from auth.stevensed.org, signed with the shared secret (Stevensed::IdentityEvents.verify_request).
#
#   GET  /stevensed/identity/events?since=<epoch seconds>&limit=  completed envelopes of the forms identity acts on,
#        as the same events the push channel sends, oldest first (identity's daily reconcile).
#   POST /stevensed/identity/envelopes  { request_id, form_key, sent_by, student_id, household_id,
#                                         guardian: { name, email }, student: { name } }
#        creates and sends an envelope of the version of that form in effect today, with the student and household
#        IDs on its submitters' metadata and the guardian's details filled in. The StevensED role goes to the staff
#        member who sent it when they have an Agreements account. Repeating a request_id returns the first envelope.
class StevensedIdentityController < ActionController::API
  REQUEST_ID = /\A[A-Za-z0-9_-]{8,64}\z/
  ID = /\A[A-Za-z0-9_-]{1,64}\z/
  FORM_KEY = /\AFRM-\d{3}(?:-[A-Z0-9]+)?\z/
  STAFF_ROLE = /\AStevensED\z/i
  MAX_EVENTS = 200

  before_action :verify_signature

  def events
    since = Time.zone.at(params[:since].to_s.match?(/\A\d{1,11}\z/) ? params[:since].to_i : 0)
    limit = params[:limit].to_i.clamp(1, MAX_EVENTS)
    limit = 100 if params[:limit].blank?

    submissions = Submission.where.not(completed_at: nil).where(completed_at: since..)
                            .joins(:template).where(templates: { external_id: managed_external_ids })
                            .preload(:template, submitters: { documents_attachments: :blob })
                            .order(:completed_at, :id).limit(limit + 1).to_a

    more = submissions.size > limit
    submissions = submissions.first(limit)

    events = submissions.map do |s|
      Stevensed::IdentityEvents.build('envelope.completed', s, event_id: "agr_#{s.id}_completed", at: s.completed_at)
    end

    render json: { events:, more:, next_since: submissions.last&.completed_at&.to_i }
  end

  def create_envelope
    body = request.request_parameters.with_indifferent_access
    problem = envelope_request_problem(body)

    return error(problem) if problem

    if (existing = existing_for(body[:request_id].to_s))
      return render json: envelope_json(existing.submission, repeated: true)
    end

    template = current_template(body[:form_key].to_s)

    return error("no version of #{body[:form_key]} is in effect", status: :not_found) unless template

    user = sender(template, body[:sent_by])

    return error('no Agreements user can send this envelope', status: :unprocessable_content) unless user

    submissions = create_submissions(template, user, body)

    render json: envelope_json(submissions.first), status: :created
  rescue Submissions::CreateFromSubmitters::BaseError, Submitters::NormalizeValues::BaseError => e
    error(e.message, status: :unprocessable_content)
  end

  private

  def envelope_request_problem(body)
    household_id = body[:household_id].to_s

    if !body[:request_id].to_s.match?(REQUEST_ID) then 'request_id is 8 to 64 letters, digits, - or _'
    elsif !body[:form_key].to_s.match?(FORM_KEY) then 'form_key is a StevensED form key such as FRM-108 or FRM-101-M'
    elsif !guardian_email(body).match?(User::EMAIL_REGEXP) then 'guardian.email is required'
    elsif !body[:student_id].to_s.match?(ID) then 'student_id is required'
    elsif household_id.present? && !household_id.match?(ID) then 'household_id is not valid'
    end
  end

  def guardian_email(body)
    body.dig(:guardian, :email).to_s.strip.downcase
  end

  def link_metadata(body)
    { Stevensed::IdentityEvents::STUDENT_ID_KEY => body[:student_id].to_s,
      Stevensed::IdentityEvents::HOUSEHOLD_ID_KEY => body[:household_id].to_s.presence,
      Stevensed::IdentityEvents::REQUEST_ID_KEY => body[:request_id].to_s,
      Stevensed::IdentityEvents::SENT_BY_KEY => body[:sent_by].to_s.strip.downcase.presence }.compact
  end

  def submitter_attrs(template, user, body)
    metadata = link_metadata(body)
    family = first_family_role(template)

    template.submitters.map do |role|
      attrs = { role: role['name'], metadata: }

      if role['name'].to_s.match?(STAFF_ROLE)
        attrs[:email] = user.email
        attrs[:name] = user.full_name.presence
      elsif role == family
        attrs[:email] = guardian_email(body)
        attrs[:name] = body.dig(:guardian, :name).to_s.squish.presence
        attrs[:values] = prefill(template, role, body)
      end

      attrs.compact
    end
  end

  def create_submissions(template, user, body)
    submitters = submitter_attrs(template, user, body).reject { |s| s[:email].blank? }
    params_hash = ActionController::Parameters.new(submitters:).permit!
    submissions_attrs, = Submissions::NormalizeParamUtils.normalize_submissions_params!([params_hash], template,
                                                                                        purpose: :api)

    submissions = Submissions.create_from_submitters(template:, user:, source: :api, submitters_order: 'preserved',
                                                     submissions_attrs:, params: { 'send_email' => true })

    WebhookUrls.enqueue_events(submissions, 'submission.created')
    Submissions.send_signature_requests(submissions)
    SearchEntries.enqueue_reindex(submissions)

    submissions
  end

  def verify_signature
    return if Stevensed::IdentityEvents.verify_request(request)

    render json: { error: 'unauthorized' }, status: :unauthorized
  end

  def error(message, status: :bad_request)
    render json: { error: message }, status:
  end

  def managed_external_ids
    Template.where("external_id ~ '^FRM-(108|101|103|105)(-[A-Z0-9]+)?_v'").pluck(:external_id)
  end

  def existing_for(request_id)
    Submitter.where('metadata LIKE ?', "%\"#{Stevensed::IdentityEvents::REQUEST_ID_KEY}\":\"#{request_id}\"%")
             .order(:id).first
  end

  # The version in effect today: the highest version whose effective date has passed (Stevensed::PolicySync).
  def current_template(form_key)
    today = Time.current.in_time_zone(Stevensed::PolicySync::TIME_ZONE).to_date

    candidates = Template.where(archived_at: nil).where('external_id LIKE ?', "#{form_key}\\_v%").to_a.select do |t|
      key, = Stevensed::Records.form_key_and_version(Submission.new(template: t))
      effective = t.preferences.to_h.dig(Stevensed::PolicySync::PREFERENCE_KEY, 'effective')

      key == form_key && (effective.blank? || Date.parse(effective) <= today)
    end

    candidates.max_by { |t| Stevensed::Records.form_key_and_version(Submission.new(template: t)).last }
  end

  def sender(template, email)
    users = template.account.users.where(archived_at: nil)

    users.find_by(email: email.to_s.strip.downcase) ||
      users.find_by(email: ENV.fetch('STEVENSED_IDENTITY_SENDER_EMAIL', '').strip.downcase.presence) ||
      template.author
  end

  def first_family_role(template)
    template.submitters.find { |s| !s['name'].to_s.match?(STAFF_ROLE) }
  end

  # Filled in for the family to check, never locked: the student's name and the guardian's name and address on file.
  def prefill(template, role, body)
    values = {}

    template.fields.select { |f| f['submitter_uuid'] == role['uuid'] && f['type'] == 'text' }.each do |f|
      name = f['name'].to_s.strip

      value =
        case name
        when Stevensed::IdentityEvents::FRM108_FIELDS[:student_name], Stevensed::IdentityEvents::STUDENT_NAME_FIELD
          body.dig(:student, :name)
        when Stevensed::IdentityEvents::FRM108_FIELDS[:parent_name] then body.dig(:guardian, :name)
        when Stevensed::IdentityEvents::FRM108_FIELDS[:parent_email] then body.dig(:guardian, :email)
        end

      values[name] = value.to_s.squish if value.present?
    end

    values
  end

  def envelope_json(submission, repeated: false)
    key, version = Stevensed::Records.form_key_and_version(submission)

    { envelope_id: submission.id, form_key: key, form_version: version&.to_s, template_id: submission.template_id,
      document_id: Digest::MD5.hexdigest(submission.slug).upcase, repeated:,
      submitters: submission.submitters.map { |s| { email: s.email, sent_at: s.sent_at&.utc&.iso8601 } } }
  end
end
