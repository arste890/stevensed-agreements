# frozen_string_literal: true

class TemplateDocumentsPageObjectsController < ApplicationController
  load_and_authorize_resource :template

  # StevensED: a page number outside the document, or a document that is not a PDF, is a client error.
  rescue_from Pdfium::PdfiumError do
    render json: { error: 'The page could not be read.' }, status: :unprocessable_content
  end

  def index
    attachment = @template.documents_attachments.find_by!(uuid: params[:attachment_uuid])

    render json: Templates::ModifyDocuments.page_objects(attachment, params[:page].to_i)
  end
end
