# frozen_string_literal: true

class SubmissionsUnarchiveController < ApplicationController
  load_and_authorize_resource :submission

  def create
    authorize!(:destroy, @submission)

    Stevensed::Records.unarchive!(@submission, user: current_user)

    redirect_to submission_path(@submission), notice: I18n.t('submission_has_been_unarchived')
  end
end
