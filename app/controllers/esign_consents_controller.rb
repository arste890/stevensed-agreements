# frozen_string_literal: true

# StevensED: the register of electronic records and signature consents on file (Stevensed::Consents).
# Admins can record a consent given on paper and mark a consent withdrawn (FRM-102 Section 5).
class EsignConsentsController < ApplicationController
  before_action -> { authorize!(:manage, current_account) }

  def index
    @consents = StevensedEsignConsent.where(account: current_account).order(withdrawn_at: :desc, signed_at: :desc)
    if params[:q].present?
      @consents = @consents.where('email ILIKE ?', "%#{StevensedEsignConsent.sanitize_sql_like(params[:q].strip)}%")
    end
    @consent = StevensedEsignConsent.new(signed_at: Time.zone.today)
  end

  def create
    consent = StevensedEsignConsent.new(consent_params.merge(account: current_account, source: 'manual'))
    consent.form_key = Stevensed::Consents::CONSENT_FORMS[consent.kind] if consent.form_key.blank?

    if consent.save
      redirect_to settings_esign_consents_path, notice: "Consent recorded for #{consent.email}."
    else
      redirect_to settings_esign_consents_path, alert: consent.errors.full_messages.to_sentence
    end
  end

  def update
    consent = StevensedEsignConsent.where(account: current_account).find(params[:id])
    consent.update!(withdrawn_at: Time.current, withdrawn_by_user: current_user,
                    note: [consent.note, params[:note].presence].compact.join("\n").presence)

    redirect_to settings_esign_consents_path, notice: "Consent for #{consent.email} marked withdrawn."
  end

  private

  def consent_params
    params.expect(stevensed_esign_consent: %i[email legal_name kind form_version signed_at note])
  end
end
