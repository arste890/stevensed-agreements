# frozen_string_literal: true

# StevensED: records the signer's consent to electronic records and signatures (ESIGN Act, 15 U.S.C. 7001(c);
# FRM-102) before the document is shown for signing. The consent appears in the audit log.
class SubmitFormEsignConsentController < ApplicationController
  include StevensedEmbeddable # StevensED: may be shown in an iframe on allowed origins

  DISCLOSURE_URL = 'https://policies.stevensed.org/#/doc/e-signature-consent'

  skip_before_action :authenticate_user!
  skip_authorization_check

  before_action :load_submitter

  def create
    return head :unprocessable_content unless consentable?

    unless @submitter.submission_events.exists?(event_type: :accept_esign_consent)
      SubmissionEvents.create_with_tracking_data(@submitter, 'accept_esign_consent', request,
                                                 { disclosure: DISCLOSURE_URL })
    end

    head :ok
  end

  private

  def consentable?
    params[:agree] == '1' &&
      !@submitter.completed_at? && !@submitter.declined_at? &&
      !@submitter.submission.archived_at? && !@submitter.submission.expired? &&
      Submitters::AuthorizedForForm.call(@submitter, current_user, request)
  end

  def load_submitter
    @submitter = Submitter.find_by!(slug: params[:submit_form_slug])
  end
end
