# frozen_string_literal: true

# StevensED: places or releases a litigation hold on a record (Records Retention Policy, INF-002 §4), which stops the
# retention sweep from disposing of it (Stevensed::Retention). Admins only.
class SubmissionsLitigationHoldController < ApplicationController
  load_and_authorize_resource :submission

  before_action :require_admin!

  def create
    Stevensed::Retention.place_hold!(@submission, user: current_user, note: params[:hold_note])

    redirect_to submission_path(@submission), notice: I18n.t('stevensed.retention.hold_placed')
  end

  def destroy
    Stevensed::Retention.release_hold!(@submission, user: current_user)

    redirect_to submission_path(@submission), notice: I18n.t('stevensed.retention.hold_released')
  end

  private

  def require_admin!
    authorize!(:manage, @submission)

    raise CanCan::AccessDenied unless current_user.role == User::ADMIN_ROLE
  end
end
