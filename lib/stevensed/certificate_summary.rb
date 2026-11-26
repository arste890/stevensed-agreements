# frozen_string_literal: true

module Stevensed
  # Public, display-only facts about an X.509 certificate for the E-signature settings page.
  # Reads the certificate only; private keys are never passed in or exposed.
  module CertificateSummary
    Summary = Struct.new(:common_name, :subject, :issuer, :not_before, :not_after, :key_algorithm, :fingerprint,
                         keyword_init: true)

    EC_CURVES = {
      'secp256r1' => 'P-256', 'prime256v1' => 'P-256', 'secp384r1' => 'P-384', 'secp521r1' => 'P-521'
    }.freeze

    module_function

    def call(certificate)
      Summary.new(
        common_name: certificate.subject.to_a.find { |key, _| key == 'CN' }&.at(1),
        subject: name_to_s(certificate.subject),
        issuer: name_to_s(certificate.issuer),
        not_before: certificate.not_before,
        not_after: certificate.not_after,
        key_algorithm: key_algorithm(certificate.public_key),
        fingerprint: OpenSSL::Digest::SHA256.hexdigest(certificate.to_der).upcase.scan(/../).join(':')
      )
    end

    def name_to_s(name)
      name.to_a.reverse.map { |key, value, _| "#{key}=#{value}" }.join(', ')
    end

    def key_algorithm(public_key)
      case public_key
      when OpenSSL::PKey::RSA
        "RSA #{public_key.n.num_bits}-bit"
      when OpenSSL::PKey::EC
        curve = public_key.group.curve_name
        "ECDSA #{EC_CURVES.fetch(curve, curve)}"
      else
        public_key.oid
      end
    end
  end
end
