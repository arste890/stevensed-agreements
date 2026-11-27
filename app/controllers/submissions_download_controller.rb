# frozen_string_literal: true

class SubmissionsDownloadController < ApplicationController
  load_and_authorize_resource :submission

  def index
    last_submitter = @submission.submitters.where.not(completed_at: nil).order(:completed_at).last

    return head :not_found unless last_submitter

    Submissions::EnsureResultGenerated.call(last_submitter)

    # StevensED: staff download, combined by default (or documents, or the audit log); "combined=true" still works.
    requested = params[:kind].presence || ('combined' if params[:combined] == 'true')
    kind = Stevensed::Downloads.resolve(@submission, requested, audience: :staff)
    urls = kind ? Stevensed::Downloads.urls(last_submitter, kind) : []

    return head :not_found if urls.empty?

    render json: urls
  end
end
