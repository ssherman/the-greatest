# frozen_string_literal: true

module Services
  module Html
    class SimplifierService
      def self.call(raw_html)
        new(raw_html).call
      end

      def initialize(raw_html)
        @raw_html = raw_html
      end

      def call
        return nil if @raw_html.blank?

        doc = Nokogiri::HTML::DocumentFragment.parse(@raw_html)
        simplify_node(doc)
        doc.to_html
      end

      private

      def simplify_node(node)
        # Remove unwanted tags and their content
        remove_unwanted_tags(node)

        # Keep only semantic attributes
        node.traverse do |element|
          next unless element.element?

          # Keep only essential attributes
          allowed_attrs = %w[id class href src alt title]
          element.attributes.each do |name, attr|
            element.remove_attribute(name) unless allowed_attrs.include?(name)
          end
        end

        node
      end

      def remove_unwanted_tags(doc)
        # Define all unwanted tags in logical groups
        unwanted_tags = [
          # Scripts and styles
          "script", "style", "link", "meta", "noscript",

          # Media elements
          "img", "picture", "audio", "video", "source", "track", "canvas", "svg",

          # Interactive elements
          "button", "form", "input", "select", "textarea", "label", "fieldset",
          "legend", "optgroup", "option", "datalist", "output", "progress", "meter",

          # Embedded content
          "iframe", "embed", "object", "param", "map", "area",

          # Semantic but unwanted for parsing
          "figure", "figcaption", "dialog", "menu", "menuitem", "details",
          "summary", "slot", "template",

          # Navigation and structure that could confuse parsing
          "nav", "aside", "footer", "header",

          # Ruby annotation (rare but could interfere)
          "ruby", "rt", "rp",

          # Time and data elements that might not be relevant
          "time", "data",

          # Abbreviations and definitions that could add noise
          "abbr", "dfn",

          # Code elements that might contain non-list content
          "code", "pre", "samp", "kbd", "var",

          # Quote elements that might wrap list items confusingly
          "blockquote", "q", "cite"
        ]

        # Remove all unwanted tags in one operation
        doc.search(unwanted_tags.join(", ")).remove
      end
    end
  end
end
