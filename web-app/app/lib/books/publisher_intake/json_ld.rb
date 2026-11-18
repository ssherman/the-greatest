# frozen_string_literal: true

module Books
  module PublisherIntake
    module JsonLd
      # Every JSON-LD node, at any depth and inside @graph, whose @type
      # includes one of types. A script that is not valid JSON is skipped.
      def self.nodes(html, types:)
        wanted = Array(types).map(&:to_s)
        found = []
        Nokogiri::HTML(html.to_s).css('script[type="application/ld+json"]').each do |script|
          walk(JSON.parse(script.text), wanted, found)
        rescue JSON::ParserError
          next
        end
        found
      end

      def self.walk(value, wanted, found)
        case value
        when Hash
          found << value if (Array(value["@type"]).map(&:to_s) & wanted).any?
          value.each_value { |child| walk(child, wanted, found) }
        when Array
          value.each { |child| walk(child, wanted, found) }
        end
      end

      private_class_method :walk
    end
  end
end
