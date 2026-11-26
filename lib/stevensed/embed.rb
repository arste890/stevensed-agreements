# frozen_string_literal: true

module Stevensed
  # StevensED: settings shared by the embedded signing form and the embedded template builder.
  #
  # EMBED_ALLOWED_ORIGINS is a space or comma separated list of origins that may place the signing form
  # or the builder in an iframe. A leading "*." matches any subdomain of the given host.
  module Embed
    DEFAULT_ALLOWED_ORIGINS = 'https://stevensed.org https://*.stevensed.org'
    ORIGIN_REGEXP = %r{\A(https?)://(\*\.)?([a-z0-9-]+(?:\.[a-z0-9-]+)*)(:\d{1,5})?\z}

    module_function

    def allowed_origins
      ENV.fetch('EMBED_ALLOWED_ORIGINS', DEFAULT_ALLOWED_ORIGINS).to_s.split(/[\s,]+/).filter_map do |value|
        normalize_origin(value)
      end.uniq
    end

    def normalize_origin(value)
      origin = value.to_s.strip.downcase.delete_suffix('/')

      origin if origin.match?(ORIGIN_REGEXP)
    end

    def frame_ancestors
      [:self, *allowed_origins]
    end

    def origin_allowed?(origin)
      origin = origin.to_s.downcase

      allowed_origins.any? do |pattern|
        scheme, wildcard, host, port = pattern.match(ORIGIN_REGEXP).captures

        if wildcard
          suffix = Regexp.escape(".#{host}#{port}")

          origin.match?(%r{\A#{scheme}://[a-z0-9-]+(?:\.[a-z0-9-]+)*#{suffix}\z})
        else
          origin == pattern
        end
      end
    end
  end
end
