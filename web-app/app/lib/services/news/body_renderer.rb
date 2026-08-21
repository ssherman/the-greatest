module Services
  module News
    # The ONE place a news post's Markdown becomes HTML. Public pages, the RSS
    # feed and the admin preview all go through here, so the preview cannot
    # drift from what visitors see.
    #
    # Nothing writes through this class. NewsPost#body stores the author's
    # Markdown byte-for-byte and this runs on read, which is what makes the
    # "a sanitizer fed its own output" class of bug unrepresentable here --
    # the output is HTML and is never parsed back into the column.
    #
    # Two layers, because they fail differently:
    #   1. commonmarker with unsafe: false escapes raw HTML in the source rather
    #      than emitting it (a <script> becomes an "<!-- raw HTML omitted -->"
    #      comment).
    #   2. SafeListSanitizer enforces an explicit allowlist over the result.
    # Either alone would very likely be enough. Both is cheap.
    class BodyRenderer
      ALLOWED_TAGS = %w[
        p br a em strong del code pre blockquote hr img
        ul ol li h2 h3 h4
        table thead tbody tr th td
      ].freeze

      ALLOWED_ATTRIBUTES = %w[href title src alt].freeze

      # The page title is already the page's <h1>, so a body heading must never
      # be one. Everything at h4 or deeper flattens to h4 rather than
      # disappearing.
      HEADING_SHIFT = {"h1" => "h2", "h2" => "h3", "h3" => "h4"}.freeze
      HEADING_SELECTOR = "h1,h2,h3,h4,h5,h6".freeze

      COMMONMARKER_OPTIONS = {
        # hardbreaks: true is commonmarker's own default, pinned here
        # deliberately rather than inherited. It makes a single newline inside
        # a paragraph render as <br>, which is what an author typing in the
        # admin textarea expects from pressing Enter once. A gem upgrade that
        # flipped the default would otherwise reflow every post body silently.
        render: {unsafe: false, hardbreaks: true},
        # header_ids: nil suppresses commonmarker's default anchor injection.
        # With it on, every heading gets <a href="#slug" class="anchor"></a>;
        # the sanitizer drops class but keeps href, leaving an empty link
        # inside every heading.
        extension: {header_ids: nil, table: true, strikethrough: true, autolink: true}
      }.freeze

      def self.call(markdown) = new(markdown).call

      def initialize(markdown)
        @markdown = markdown
      end

      def call
        return "".html_safe if @markdown.blank?

        fragment = Nokogiri::HTML5.fragment(to_html)
        shift_headings(fragment)
        sanitize(fragment.to_html)
      end

      private

      def to_html
        Commonmarker.to_html(@markdown.to_s, options: COMMONMARKER_OPTIONS)
      end

      # css() returns a snapshot NodeSet and renaming a node adds no nodes, so a
      # single pass cannot double-shift an h1 into h3.
      def shift_headings(fragment)
        fragment.css(HEADING_SELECTOR).each do |node|
          node.name = HEADING_SHIFT.fetch(node.name, "h4")
        end
      end

      def sanitize(html)
        Rails::HTML5::SafeListSanitizer.new
          .sanitize(html, tags: ALLOWED_TAGS, attributes: ALLOWED_ATTRIBUTES)
          .html_safe
      end
    end
  end
end
