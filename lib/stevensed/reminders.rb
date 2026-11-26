# frozen_string_literal: true

module Stevensed
  # StevensED: automatic signature request reminders. Durations come from Settings > Notifications
  # (AccountConfig::SUBMITTER_REMINDERS) and are cumulative from the first invitation.
  module Reminders
    KEYS = %w[first_duration second_duration third_duration].freeze

    module_function

    def durations(account)
      config = AccountConfig.find_by(account:, key: AccountConfig::SUBMITTER_REMINDERS)
      values = config&.value.is_a?(Hash) ? config.value.values_at(*KEYS) : []

      values.filter_map { |key| parse(AccountConfigs::REMINDER_DURATIONS[key]) }
    end

    def parse(text)
      count, unit = text.to_s.split
      return if count.to_i <= 0 || unit.blank?

      count.to_i.public_send(unit.singularize.to_sym)
    rescue NoMethodError
      nil
    end

    def schedule(submitter)
      return if submitter.email.blank? || submitter.viewer?

      elapsed = 0.seconds

      durations(submitter.account).each_with_index do |duration, index|
        elapsed += duration

        SendSubmitterInvitationEmailJob.perform_in(elapsed.to_i, 'submitter_id' => submitter.id,
                                                                 'reminder' => true,
                                                                 'reminder_index' => index + 1)
      end
    end
  end
end
