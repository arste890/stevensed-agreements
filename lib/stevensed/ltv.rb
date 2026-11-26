# frozen_string_literal: true

require 'net/http'

module Stevensed
  # Long-term validation (PAdES B-LT): after signing, add a Document Security Store with the signer's
  # certificate chain, the time-stamp authority's certificates, and current CRLs for each of them, so the
  # signature can be validated after the certificates expire or the CRL servers change.
  module Ltv
    TIMESTAMP_TOKEN_OID = '1.2.840.113549.1.9.16.2.14'
    CRL_TTL = 12.hours

    module_function

    def call(io)
      io.rewind
      doc = HexaPDF::Document.new(io: StringIO.new(io.string.dup))
      signature = doc.signatures.to_a.last
      return io unless signature

      certs = collect_certificates(signature.contents)
      crls = certs.flat_map { |cert| fetch_crls(cert) }.uniq(&:to_der)

      add_dss(doc, certs, crls)

      out = StringIO.new
      doc.write(out, incremental: true, validate: false)
      io.truncate(0)
      io.rewind
      io.write(out.string)
      io
    rescue StandardError => e
      Rails.logger.warn("StevensED LTV skipped: #{e.class}: #{e.message}")
      io
    end

    def collect_certificates(contents)
      der = contents.to_s.b.sub(/\x00+\z/n, '')
      pkcs7 = OpenSSL::PKCS7.new(der)
      certs = Array(pkcs7.certificates) + VaultSigning.chain

      if (token = find_timestamp_token(OpenSSL::ASN1.decode(der)))
        certs += Array(OpenSSL::PKCS7.new(token.to_der).certificates)
      end

      certs.uniq(&:to_der)
    end

    def find_timestamp_token(node)
      return unless node.respond_to?(:value) && node.value.is_a?(Array)

      node.value.each_with_index do |child, index|
        if child.is_a?(OpenSSL::ASN1::ObjectId) && child.oid == TIMESTAMP_TOKEN_OID
          set = node.value[index + 1]
          return set.value.first if set.respond_to?(:value) && set.value.is_a?(Array)
        end

        found = find_timestamp_token(child)
        return found if found
      end

      nil
    end

    def crl_urls(cert)
      ext = cert.extensions.find { |e| e.oid == 'crlDistributionPoints' }
      return [] unless ext

      ext.value.scan(/URI:(http[^\s,]+)/).flatten
    end

    def fetch_crls(cert)
      return [] if cert.subject == cert.issuer

      crl_urls(cert).first(2).filter_map do |url|
        der = Rails.cache.fetch("stevensed:crl:#{url}", expires_in: CRL_TTL) { http_get(url) }
        OpenSSL::X509::CRL.new(der) if der
      rescue OpenSSL::X509::CRLError
        nil
      end
    end

    def http_get(url)
      uri = URI(url)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 5,
                                                     read_timeout: 10) { |http| http.get(uri.request_uri) }
      response.is_a?(Net::HTTPSuccess) ? response.body.b : nil
    end

    def add_dss(doc, certs, crls)
      dss = doc.catalog[:DSS] || doc.add({})
      dss[:Certs] = Array(dss[:Certs]) + certs.map { |c| doc.add({}, stream: c.to_der) }
      dss[:CRLs] = Array(dss[:CRLs]) + crls.map { |c| doc.add({}, stream: c.to_der) } if crls.any?
      doc.catalog[:DSS] = dss
    end
  end
end
