# frozen_string_literal: true

module Books
  module PublisherIntake
    # Cuts a captured page down to a test fixture: what a parser reads and
    # little else. Scripts other than JSON-LD, styles, svg, noscript, iframes,
    # comments and srcset attributes go; any text longer than LONG_TEXT
    # characters (page copy, and string values inside JSON-LD) is cut to its
    # first sentence, because fixtures are committed to a public repository.
    module FixtureTrimmer
      LONG_TEXT = 200
      REMOVED = %w[style svg noscript iframe].freeze

      def self.call(html)
        doc = Nokogiri::HTML(html.to_s)
        doc.css(REMOVED.join(",")).each(&:remove)
        doc.css("script").each { |script| trim_script(script) }
        doc.xpath("//comment()").each(&:remove)
        doc.css("img[srcset], source[srcset]").each { |node| node.remove_attribute("srcset") }
        doc.xpath("//text()").each { |node| node.content = shorten(node.content) unless node.parent&.name == "script" }
        doc.to_html
      end

      def self.shorten(text)
        return text if text.length <= LONG_TEXT

        first = text.strip[/\A.+?[.!?](?=\s|\z)/m] || text.strip
        (first.length > LONG_TEXT) ? "#{first[0, LONG_TEXT].rstrip}." : first
      end

      def self.trim_script(script)
        return script.remove unless script["type"] == "application/ld+json"

        script.content = JSON.generate(trim_json(JSON.parse(script.text)))
      rescue JSON::ParserError
        script.remove
      end

      def self.trim_json(value)
        case value
        when String then shorten(value)
        when Array then value.map { |child| trim_json(child) }
        when Hash then value.transform_values { |child| trim_json(child) }
        else value
        end
      end

      private_class_method :shorten, :trim_script, :trim_json
    end
  end
end
