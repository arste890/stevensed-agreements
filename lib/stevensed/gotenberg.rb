# frozen_string_literal: true

require 'net/http'

module Stevensed
  # StevensED: client for the Gotenberg container (LibreOffice and Chromium) on the private Docker network.
  module Gotenberg
    Error = Class.new(StandardError)

    DEFAULT_MARGIN = 0.5
    HEADER_FOOTER_MARGIN = 1.0

    module_function

    def office_to_pdf(file)
      file.rewind if file.respond_to?(:rewind)
      post('/forms/libreoffice/convert', [['files', file.original_filename.to_s, file.read]])
    end

    # Paper sizes and margins are in inches. The optional header and footer are complete HTML documents that
    # Chromium repeats on every page inside the top and bottom margins.
    def html_to_pdf(html, paper_width: nil, paper_height: nil, header: nil, footer: nil)
      parts = [['files', 'index.html', html]]
      parts << ['files', 'header.html', header] if header.present?
      parts << ['files', 'footer.html', footer] if footer.present?

      fields = { 'printBackground' => 'true' }

      if paper_width && paper_height
        fields['paperWidth'] = paper_width.to_s
        fields['paperHeight'] = paper_height.to_s
        fields['marginTop'] = (header.present? ? HEADER_FOOTER_MARGIN : DEFAULT_MARGIN).to_s
        fields['marginBottom'] = (footer.present? ? HEADER_FOOTER_MARGIN : DEFAULT_MARGIN).to_s
        fields['marginLeft'] = DEFAULT_MARGIN.to_s
        fields['marginRight'] = DEFAULT_MARGIN.to_s
      end

      post('/forms/chromium/convert/html', parts, fields)
    end

    def post(path, files, fields = {})
      uri = URI.join(ENV.fetch('GOTENBERG_URL'), path)
      boundary = "stevensed#{SecureRandom.hex(12)}"

      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = "multipart/form-data; boundary=#{boundary}"
      request.body = multipart_body(boundary, files, fields)

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                                     open_timeout: 10, read_timeout: 120) do |http|
        http.request(request)
      end

      raise Error, "Gotenberg #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      response.body
    end

    def multipart_body(boundary, files, fields)
      body = String.new(encoding: Encoding::BINARY)

      fields.each do |name, value|
        body << "--#{boundary}\r\n"
        body << "Content-Disposition: form-data; name=\"#{name}\"\r\n\r\n"
        body << value.to_s.b << "\r\n"
      end

      files.each do |field, filename, data|
        body << "--#{boundary}\r\n"
        body << "Content-Disposition: form-data; name=\"#{field}\"; filename=\"#{filename.tr('"', '')}\"\r\n".b
        body << "Content-Type: application/octet-stream\r\n\r\n"
        body << data.to_s.b << "\r\n"
      end

      body << "--#{boundary}--\r\n"
    end
  end
end
