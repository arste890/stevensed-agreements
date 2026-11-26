# frozen_string_literal: true

# StevensED: white-label upstream strings (see config/initializers/stevensed_i18n.rb).
module Stevensed
  module I18nWhiteLabel
    REPLACEMENTS = [
      ['https://www.docuseal.com/privacy', 'https://stevensed.org/privacy/'],
      ['https://www.docuseal.com/terms', 'https://stevensed.org/terms/'],
      ['support@docuseal.com', Stevensed::CONTACT_EMAIL],
      ['To resolve this, follow this <a href="https://www.docuseal.com/resources/pre-filling-recipients" ' \
       'class="link font-bold" rel="noopener noreferrer nofollow" target="_blank">guide</a> to define the ' \
       'default signer details.',
       'To resolve this, open the template and set default signer details for the other parties.'],
      # Upstream help articles are not StevensED documentation: keep the link text, drop the link.
      [%r{<a href="https://www\.docuseal\.com/resources/[^"]*"[^>]*>(.*?)</a>}, '\\1'],
      ["DocuSeal's", "#{Stevensed::PRODUCT_NAME}'s"],
      ['DocuSeal Pro', Stevensed::PRODUCT_NAME],
      ['DocuSeal Console', Stevensed::PRODUCT_NAME],
      ['DocuSeal', Stevensed::PRODUCT_NAME]
    ].freeze

    module_function

    def apply(value)
      case value
      when String then REPLACEMENTS.reduce(value) { |acc, (from, to)| acc.gsub(from, to) }
      when Hash then value.transform_values { |v| apply(v) }
      when Array then value.map { |v| apply(v) }
      else value
      end
    end

    def install!
      backend = I18n.backend
      backend.send(:init_translations) unless backend.initialized?
      backend.send(:translations).each_key do |locale|
        backend.send(:translations)[locale] = apply(backend.send(:translations)[locale])
      end
    end
  end
end
