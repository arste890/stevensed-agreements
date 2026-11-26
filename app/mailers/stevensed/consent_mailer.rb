# frozen_string_literal: true

module Stevensed
  # StevensED: alerts to the Office of Legal Operations from the electronic records consent step.
  class ConsentMailer < ApplicationMailer
    def wrong_version_email(submitter, student_age, expected)
      @submitter = submitter
      @submission = submitter.submission
      @student_age = student_age
      @expected = expected

      alert(submitter, 'stevensed_wrong_version', "Envelope voided: wrong version for the student's age " \
                                                   "(envelope #{@submission.id})")
    end

    def paper_request_email(submitter)
      @submitter = submitter
      @submission = submitter.submission

      alert(submitter, 'stevensed_paper_request', "Paper copies requested instead of electronic signing " \
                                                  "(envelope #{@submission.id})")
    end

    def parent_consent_missing_email(submitter)
      @submitter = submitter
      @submission = submitter.submission

      alert(submitter, 'stevensed_parent_consent_missing', "Parent consent needed before a minor student can sign " \
                                                           "(envelope #{@submission.id})")
    end

    private

    def alert(submitter, tag, subject)
      @current_account = submitter.account
      assign_message_metadata(tag, submitter)

      mail(to: Stevensed::CONTACT_EMAIL, subject: "StevensED Agreements: #{subject}")
    end
  end
end
