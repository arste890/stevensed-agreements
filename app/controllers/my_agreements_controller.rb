# frozen_string_literal: true

# StevensED client portal: agreements the signed-in person has signed or been asked to sign,
# matched by the verified email address of their StevensED account.
class MyAgreementsController < ApplicationController
  skip_authorization_check

  def index
    @submitters =
      Submitter.where(account_id: current_account.id)
               .where('LOWER(submitters.email) = ?', current_user.email.to_s.downcase)
               .where(declined_at: nil)
               .joins(:submission).where(submissions: { archived_at: nil })
               .preload(submission: :template)
               .order(Arel.sql('submitters.completed_at IS NULL DESC, submitters.completed_at DESC, ' \
                               'submitters.created_at DESC'))
               .limit(500)
  end
end
