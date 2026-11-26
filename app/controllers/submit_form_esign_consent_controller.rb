# frozen_string_literal: true

# StevensED: the electronic records consent step before signing (see Stevensed::Consents).
# Steps: "dob" (student date of birth, family envelopes), "consent" (open the one-time consent form),
# "checkbox" (fallback when no consent form is published), "paper" (ask for paper copies instead).
class SubmitFormEsignConsentController < ApplicationController
  include StevensedEmbeddable # StevensED: may be shown in an iframe on allowed origins

  skip_before_action :authenticate_user!
  skip_authorization_check

  before_action :load_submitter

  def create
    unless consentable?
      return render json: { error: 'This envelope can no longer be signed.' }, status: :unprocessable_content
    end

    case params[:step]
    when 'dob' then submit_dob
    when 'consent' then open_consent
    when 'checkbox' then accept_checkbox
    when 'paper' then request_paper
    else render json: { error: 'Unknown step.' }, status: :unprocessable_content
    end
  end

  private

  def submit_dob
    dob = parse_dob
    return render json: { error: "Enter the student's date of birth." }, status: :unprocessable_content unless dob

    ctx = Stevensed::Consents.context(@submitter)
    band = Stevensed::Consents.age_band(dob)

    unless Stevensed::Consents.band_matches?(ctx, band)
      Stevensed::Consents.void!(@submitter, ctx, band)

      return render json: { redirect: submit_form_path(@submitter.slug) }
    end

    Stevensed::Consents.store_age!(@submitter, dob, band)
    Stevensed::Consents.prepare(@submitter, request)

    render json: { reload: true }
  end

  def open_consent
    ctx = Stevensed::Consents.context(@submitter)
    kind = Stevensed::Consents.kinds_for(ctx, @submitter.metadata.to_h['stevensed_student_age']).first
    consent_submitter = Stevensed::Consents.start_consent!(@submitter, kind, submit_form_url(@submitter.slug))

    return render json: { reload: true } unless consent_submitter

    render json: { redirect: submit_form_path(consent_submitter.slug) }
  end

  def accept_checkbox
    return render json: { error: 'Tick the box to agree.' }, status: :unprocessable_content unless params[:agree] == '1'

    unless Stevensed::Consents.accepted?(@submitter)
      Stevensed::Consents.accept!(@submitter, request, band: @submitter.metadata.to_h['stevensed_student_age'],
                                                       source: 'checkbox')
    end

    render json: { reload: true }
  end

  def request_paper
    Stevensed::Consents.request_paper!(@submitter)

    render json: { message: 'Thank you. The Office of Legal Operations and Institutional Compliance will contact ' \
                            'you to arrange paper copies.' }
  end

  def parse_dob
    date = Date.iso8601(params[:dob].to_s)
    date if date <= Time.zone.today && date.year >= 1900
  rescue Date::Error
    nil
  end

  def consentable?
    !@submitter.completed_at? && !@submitter.declined_at? && !@submitter.viewer? &&
      !@submitter.submission.archived_at? && !@submitter.submission.expired? &&
      Submitters::AuthorizedForForm.call(@submitter, current_user, request)
  end

  def load_submitter
    @submitter = Submitter.find_by!(slug: params[:submit_form_slug])
  end
end
