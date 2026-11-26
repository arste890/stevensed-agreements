# frozen_string_literal: true

module Stevensed
  # StevensED: copy and paste examples shown in Settings, Embedding.
  module EmbedSnippets
    module_function

    def call(app_url:, template: nil)
      template_id = template&.id || 123
      template_slug = template&.slug || 'TEMPLATE_SLUG'

      {
        form: form(app_url),
        share_link: share_link(app_url, template_slug),
        builder: builder(app_url),
        ruby_token: ruby_token(template_id),
        node_token: node_token(template_id),
        python_token: python_token(template_id),
        html_template: html_template(app_url)
      }
    end

    def form(app_url)
      <<~HTML
        <script src="#{app_url}/js/form.js"></script>

        <stevensed-form data-src="#{app_url}/s/SUBMITTER_SLUG"></stevensed-form>

        <script>
          const form = document.querySelector('stevensed-form')

          form.addEventListener('completed', (event) => {
            // event.detail: submitter_id, submitter_slug, download_url
            console.log('Signed by submitter', event.detail.submitter_id)
          })

          form.addEventListener('declined', (event) => {
            console.log('Declined by submitter', event.detail.submitter_id)
          })
        </script>
      HTML
    end

    def share_link(app_url, template_slug)
      <<~HTML
        <stevensed-form
          data-src="#{app_url}/d/#{template_slug}"
          data-email="family@example.com"
          data-name="Jordan Lee"
          data-language="en">
        </stevensed-form>
      HTML
    end

    def builder(app_url)
      <<~HTML
        <script src="#{app_url}/js/builder.js"></script>

        <stevensed-builder data-token="TOKEN_FROM_YOUR_SERVER"></stevensed-builder>

        <script>
          document.querySelector('stevensed-builder').addEventListener('save', (event) => {
            console.log('Template saved', event.detail.template_id)
          })
        </script>
      HTML
    end

    def ruby_token(template_id)
      <<~RUBY
        require 'jwt'

        token = JWT.encode(
          {
            user_email: 'editor@stevensed.org', # an admin or editor in #{Stevensed::PRODUCT_NAME}
            template_id: #{template_id}, # or external_id: 'your-template-id'
            iat: Time.now.to_i,
            exp: Time.now.to_i + (15 * 60) # at most one hour
          },
          ENV.fetch('AGREEMENTS_API_TOKEN'), # that user's API token from Settings, API
          'HS256'
        )
      RUBY
    end

    def node_token(template_id)
      <<~JAVASCRIPT
        // Node.js with the jsonwebtoken package
        const jwt = require('jsonwebtoken')

        const token = jwt.sign(
          { user_email: 'editor@stevensed.org', template_id: #{template_id} },
          process.env.AGREEMENTS_API_TOKEN,
          { algorithm: 'HS256', expiresIn: '15m' }
        )
      JAVASCRIPT
    end

    def python_token(template_id)
      <<~PYTHON
        # Python with the PyJWT package
        import os, time, jwt

        now = int(time.time())
        token = jwt.encode(
            {"user_email": "editor@stevensed.org", "template_id": #{template_id}, "iat": now, "exp": now + 900},
            os.environ["AGREEMENTS_API_TOKEN"],
            algorithm="HS256",
        )
      PYTHON
    end

    def html_template(app_url)
      <<~SHELL
        curl --location '#{app_url}/api/templates/html' \\
             --header 'X-Auth-Token: API_TOKEN' \\
             --header 'Content-Type: application/json' \\
             --data-raw '{
               "name": "Enrollment agreement",
               "size": "Letter",
               "html": "<h1>Enrollment agreement</h1><p>Parent name: <text-field name=\\"Parent name\\" role=\\"Parent\\"></text-field></p><p><signature-field name=\\"Parent signature\\" role=\\"Parent\\"></signature-field></p>"
             }'
      SHELL
    end
  end
end
