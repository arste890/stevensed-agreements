# frozen_string_literal: true

# StevensED: an electronic records and signature consent on file for one signer (by email).
class StevensedEsignConsent < ApplicationRecord
  KINDS = %w[family_minor family_adult staff general].freeze
  SOURCES = %w[signed packet manual].freeze

  belongs_to :account
  belongs_to :submission, optional: true
  belongs_to :submitter, optional: true
  belongs_to :withdrawn_by_user, class_name: 'User', optional: true

  validates :email, :legal_name, :form_key, :signed_at, presence: true
  validates :kind, inclusion: { in: KINDS }
  validates :source, inclusion: { in: SOURCES }

  before_validation { self.email = email.to_s.strip.downcase }

  scope :active, -> { where(withdrawn_at: nil) }

  def family?
    kind.start_with?('family')
  end

  def label
    [form_key, form_version && "v#{form_version}"].compact.join(' ')
  end
end
