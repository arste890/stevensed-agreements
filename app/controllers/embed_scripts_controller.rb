# frozen_string_literal: true

# StevensED: serves the embed scripts for the signing form (/js/form.js), the template builder
# (/js/builder.js) and the bridge loaded inside embedded pages (/js/frame.js).
class EmbedScriptsController < ActionController::Metal
  SCRIPTS_PATH = Rails.root.join('app/javascript/embed')

  SCRIPTS = %w[form builder frame].index_with do |name|
    SCRIPTS_PATH.join("#{name}.js").read.freeze
  end.freeze

  def show
    script = SCRIPTS[params[:filename].to_s.delete_suffix('.js')]

    headers['X-Content-Type-Options'] = 'nosniff'

    if script
      headers['Content-Type'] = 'application/javascript; charset=utf-8'
      headers['Cache-Control'] = 'public, max-age=300'

      self.response_body = script
      self.status = 200
    else
      headers['Content-Type'] = 'text/plain; charset=utf-8'

      self.response_body = 'Not found'
      self.status = 404
    end
  end
end
