# frozen_string_literal: true

module Stevensed
  module HtmlTemplates
    # StevensED: removes active content and network references from template HTML before conversion.
    #
    # Scripts, frames, plugins, forms, media and external style sheets are removed, as are event handler
    # attributes. Resource references (src, href outside links, CSS url() and @import) are kept only when they
    # are inline data: URLs, so the converter never requests a network address. Links in <a href> may use
    # http, https, mailto or tel.
    module HtmlSanitizer
      REMOVED_ELEMENTS = %w[
        script noscript iframe frame frameset object embed applet portal link meta base
        form input button textarea select option datalist
        audio video source track use foreignobject animate animatemotion animatetransform set
      ].freeze

      REMOVED_ATTRIBUTES = %w[srcset formaction action ping background poster lowsrc dynsrc manifest].freeze
      RESOURCE_ATTRIBUTES = %w[src href xlink:href].freeze
      LINK_REGEXP = /\A(?:https?:|mailto:|tel:|#)/i
      DATA_URL_REGEXP = %r{\Adata:(?:image|font)/[a-z0-9.+-]+[;,]}i
      CSS_URL_REGEXP = /url\(\s*(['"]?)(.*?)\1\s*\)/im
      CSS_IMPORT_REGEXP = /@import\b[^;]*;?/i
      CSS_IMAGE_SET_REGEXP = /(?:-webkit-)?image-set\(/i
      CSS_ESCAPE_DECODED_REGEXP = %r{\A[a-z(@:/.]\z}i

      module_function

      def call(html)
        document = Nokogiri::HTML5.parse(html.to_s)

        document.css('*').to_a.each do |node|
          next node.remove if REMOVED_ELEMENTS.include?(node.name.downcase)

          scrub_attributes(node)
        end

        document.css('style').each { |node| node.content = scrub_css(node.content) }

        document
      end

      def scrub_attributes(node)
        node.attribute_nodes.each do |attribute|
          name = attribute.name.downcase
          qualified_name = [attribute.namespace&.prefix, attribute.name].compact.join(':').downcase

          if name.start_with?('on') || REMOVED_ATTRIBUTES.include?(name)
            attribute.remove
          elsif RESOURCE_ATTRIBUTES.include?(qualified_name) || RESOURCE_ATTRIBUTES.include?(name)
            attribute.remove unless allowed_reference?(node, name, attribute.value)
          elsif name == 'style'
            attribute.value = scrub_css(attribute.value)
          end
        end
      end

      def allowed_reference?(node, name, value)
        value = value.to_s.gsub(/[[:space:][:cntrl:]]/, '')

        return value.match?(LINK_REGEXP) if node.name.downcase == 'a' && name == 'href'
        return true if value.start_with?('#') && node.name.downcase != 'img'

        value.match?(DATA_URL_REGEXP)
      end

      def scrub_css(css)
        css = decode_css_escapes(css.to_s).gsub(CSS_IMPORT_REGEXP, '').gsub(CSS_IMAGE_SET_REGEXP, 'none-set(')

        css.gsub(CSS_URL_REGEXP) do
          url = Regexp.last_match(2).to_s.gsub(/[[:space:][:cntrl:]]/, '')

          url.match?(DATA_URL_REGEXP) || url.start_with?('#') ? "url(\"#{url.delete('"')}\")" : 'none'
        end
      end

      # Decodes escapes that could spell url( or @import, such as \75 rl(, and leaves other escapes untouched.
      def decode_css_escapes(css)
        css.gsub(/\\(?:([0-9a-f]{1,6})[ \t\n]?|([g-z(@]))/i) do
          match = Regexp.last_match
          char = match[1] ? [match[1].hex].pack('U') : match[2]

          char.match?(CSS_ESCAPE_DECODED_REGEXP) ? char : match[0]
        rescue RangeError
          match[0]
        end
      end
    end
  end
end
