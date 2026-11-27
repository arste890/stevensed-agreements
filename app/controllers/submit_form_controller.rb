# frozen_string_literal: true

class SubmitFormController < ApplicationController
  include StevensedEmbeddable # StevensED: may be shown in an iframe on allowed origins

  layout 'form'

  around_action :with_browser_locale, only: %i[show completed success delegated]
  skip_before_action :authenticate_user!
  skip_authorization_check

  before_action :load_submitter, only: %i[show update completed]
  before_action :maybe_render_not_found_for_search_bot, only: %i[show completed]
  before_action :maybe_redirect_delegated, only: %i[show completed]
  before_action :maybe_render_locked_page, only: :show
  before_action :maybe_require_link_2fa, only: %i[show]

  CONFIG_KEYS = [].freeze

  # StevensED: an unknown or replaced signing link gets a page with a contact, not a bare JSON error.
  rescue_from ActiveRecord::RecordNotFound, with: :render_signing_link_not_found

  def show
    submission = @submitter.submission

    return render :email_2fa unless Submitters::AuthorizedForForm.pass_email_2fa?(@submitter, request)

    if @submitter.completed_at? || submission.completed_at?
      return redirect_to submit_form_completed_path(@submitter.slug, lang:)
    end

    @form_configs = Submitters::FormConfigs.call(@submitter, CONFIG_KEYS)

    return render :awaiting if (@form_configs[:enforce_signing_order] ||
                                submission.template&.preferences&.dig('submitters_order') == 'preserved') &&
                               !Submitters.current_submitter_order?(@submitter)

    # StevensED: electronic records consent on file (Stevensed::Consents); may apply the signer's legal name.
    @stevensed_consent_gate = Stevensed::Consents.prepare(@submitter, request)

    Submissions.preload_with_pages(submission)

    @attachments_index = build_attachments_index(submission)

    if current_user && current_user.email == @submitter.email
      @current_user_data = current_user.as_json(only: %i[first_name last_name], methods: %i[full_name])
    end

    # StevensED: no signature or initials are carried over from another envelope or from a saved user profile.
    # Office mailboxes (legal@, info@, admin@, bursar@) are shared, so a remembered signature for an email address
    # could belong to a different person. Each signer signs fresh in each envelope.
    @prefill_signature = nil
    @prefill_initials = nil
  end

  def update
    unless Submitters::AuthorizedForForm.call(@submitter, current_user, request, with_order: with_order(@submitter))
      return render json: { error: I18n.t('verification_required_refresh_the_page_and_pass_2fa') },
                    status: :unprocessable_content
    end

    if @submitter.completed_at?
      return render json: { error: I18n.t('form_has_been_completed_already') }, status: :unprocessable_content
    end

    if @submitter.submission.template&.archived_at? || @submitter.submission.archived_at?
      return render json: { error: I18n.t('form_has_been_archived') }, status: :unprocessable_content
    end

    if @submitter.submission.expired?
      return render json: { error: I18n.t('form_has_been_expired') }, status: :unprocessable_content
    end

    if @submitter.declined_at?
      return render json: { error: I18n.t('form_has_been_declined') },
                    status: :unprocessable_content
    end

    if @submitter.viewer?
      Rollbar.warning("Submit viewer: #{@submitter.id}") if defined?(Rollbar)

      return render json: { error: I18n.t('form_is_view_only') }, status: :unprocessable_content
    end

    Submitters::SubmitValues.call(@submitter, params, request)

    head :ok
  rescue Submitters::SubmitValues::RequiredFieldError => e
    Rollbar.warning("Required field #{@submitter.id}: #{e.message}") if defined?(Rollbar)

    render json: { field_uuid: e.message }, status: :unprocessable_content
  rescue Submitters::SubmitValues::ValidationError => e
    Rollbar.warning("Validation error #{@submitter.id}: #{e.message}") if defined?(Rollbar)

    render json: { error: e.message }, status: :unprocessable_content
  end

  def completed
    raise ActionController::RoutingError, I18n.t('not_found') if @submitter.account.archived_at?

    # StevensED: a signer who has not finished yet goes back to the form (the page needs a completion time).
    unless @submitter.completed_at? || (@submitter.viewer? && @submitter.submission.completed_at?)
      return redirect_to submit_form_path(params[:submit_form_slug], lang:)
    end

    return if Submitters::AuthorizedForForm.call(@submitter, current_user, request)

    redirect_to submit_form_path(params[:submit_form_slug], lang:)
  end

  def success; end

  def delegated
    submitter_version = SubmitterVersion.find_by!(slug: params[:slug] || params[:submit_form_slug])

    @submitter = submitter_version.submitter

    maybe_render_locked_page
  end

  private

  def render_signing_link_not_found
    respond_to do |f|
      f.html { render :not_found, status: :not_found }
      f.any { render json: { status: 404 }, status: :not_found }
    end
  end

  def maybe_render_not_found_for_search_bot
    return unless DetectBrowserDevice.search_bot?(request.user_agent)

    Rollbar.warning("Search bot: submitter #{@submitter&.id}") if defined?(Rollbar)

    raise ActionController::RoutingError, I18n.t('not_found')
  end

  def maybe_require_link_2fa
    return if Submitters::AuthorizedForForm.pass_link_2fa?(@submitter, current_user, request)

    redirect_to start_form_path(@submitter.submission.template.slug, lang:)
  end

  def maybe_render_locked_page
    # StevensED: PolicySync archives a template when a newer form version replaces it. That locks unsigned links,
    # but a signer who already completed the record still reaches the completed page (show redirects there), where
    # the usual download rules apply. A record archived by staff, or an archived account, stays locked.
    template_locked = @submitter.submission.template&.archived_at? && !signer_finished?(@submitter)

    return render :archived if template_locked ||
                               @submitter.submission.archived_at? ||
                               @submitter.account.archived_at?
    return render :expired if @submitter.submission.expired?

    render :declined if @submitter.declined_at?
  end

  def signer_finished?(submitter)
    submitter.completed_at? || (submitter.viewer? && submitter.submission.completed_at?)
  end

  def maybe_redirect_delegated
    return if @submitter

    submitter_version = SubmitterVersion.find_by!(slug: params[:slug] || params[:submit_form_slug])

    submitter_version.submitter.submission_events.find_by!(event_type: :delegate_form)

    redirect_to submit_form_delegated_path(submitter_version.slug)
  end

  def load_submitter
    @submitter = Submitter.find_by(slug: params[:slug] || params[:submit_form_slug])
  end

  def build_attachments_index(submission)
    ActiveStorage::Attachment.where(record: submission.submitters, name: :attachments)
                             .preload(:blob).index_by(&:uuid)
  end

  def with_order(submitter)
    params[:completed] == 'true' && submitter.present? &&
      submitter.submission.template&.preferences&.dig('submitters_order') == 'preserved'
  end

  def lang
    params[:lang].presence
  end
end
