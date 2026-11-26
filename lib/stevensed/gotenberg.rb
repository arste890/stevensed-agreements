# frozen_string_literal: true

require 'net/http'

module Stevensed
  # StevensED: client for the Gotenberg container (LibreOffice and Chromium) on the private Docker network.
  module Gotenberg
    Error = Class.new(StandardError)

    module_function

    def office_to_pdf(file)
      file.rewind if file.respond_to?(:rewind)
      post('/forms/libreoffice/convert', 'files', file.original_filename.to_s, file.read)
    end

    def html_to_pdf(html)
      post('/forms/chromium/convert/html', 'files', 'index.html', html)
    end

    def post(path, field, filename, data)
      uri = URI.join(ENV.fetch('GOTENBERG_URL'), path)
      boundary = "stevensed#{SecureRandom.hex(12)}"
      body = +"--#{boundary}\r\n"
      body << "Content-Disposition: form-data; name=\"#{field}\"; filename=\"#{filename.tr('"', '')}\"\r\n"
      body << "Content-Type: application/octet-stream\r\n\r\n"
      body << data.to_s.b << "\r\n--#{boundary}--\r\n"

      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = "multipart/form-data; boundary=#{boundary}"
      request.body = body

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                                     open_timeout: 10, read_timeout: 120) do |http|
        http.request(request)
      end

      raise Error, "Gotenberg #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      response.body
    end
  end
end
