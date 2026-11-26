# frozen_string_literal: true

# StevensED: Appropriate Legal Notices (AGPLv3 sections 0, 5(d), 7(b) and 13).
class LegalNoticesController < ApplicationController
  skip_before_action :authenticate_user!
  skip_authorization_check

  def show
    render layout: 'plain'
  end
end
