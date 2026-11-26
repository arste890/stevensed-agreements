# frozen_string_literal: true

require 'net/http'

module Stevensed
  # StevensED Trusted Signature: documents are signed with the StevensED Agreements certificate, whose
  # private key is held in Oracle Cloud Vault (HSM). HexaPDF builds the CMS structure; only the digest of
  # the signed attributes is sent to the signer service (tools/signer), which calls the Vault Sign API.
  module VaultSigning
    Pkcs = Struct.new(:certificate, :ca_certs, :key, keyword_init: true)
    Error = Class.new(StandardError)

    PKI_DIR = File.expand_path('pki', __dir__)

    module_function

    def enabled?
      ENV['STEVENSED_SIGNER_URL'].present? && ENV['STEVENSED_SIGNER_TOKEN'].present?
    end

    def load_cert(name)
      OpenSSL::X509::Certificate.new(File.binread(File.join(PKI_DIR, name)))
    end

    def certificate
      @certificate ||= load_cert('stevensed-agreements.crt')
    end

    def chain
      @chain ||= [load_cert('document-signing-ca.crt'), load_cert('root-ca.crt')]
    end

    def root
      chain.last
    end

    def pkcs
      Pkcs.new(certificate:, ca_certs: chain, key: nil)
    end

    def signing_proc
      ->(digest_algorithm, hash) { sign(digest_algorithm, hash) }
    end

    def sign(digest_algorithm, hash)
      uri = URI.join(ENV.fetch('STEVENSED_SIGNER_URL'), '/sign')
      request = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json',
                                         'Authorization' => "Bearer #{ENV.fetch('STEVENSED_SIGNER_TOKEN')}")
      request.body = { algorithm: digest_algorithm.to_s, digest: Base64.strict_encode64(hash) }.to_json

      response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 20) { |http| http.request(request) }

      raise Error, "signer returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      Base64.decode64(JSON.parse(response.body).fetch('signature'))
    end
  end
end
