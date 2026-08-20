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
    #   1. commonmarker with unsafe: true and tagfilter: false lets any raw
    #      HTML in the source through as real, well-formed elements instead of
    #      commonmarker's own ad-hoc neutralising (block-level raw HTML is
    #      "clobbered" as ONE opaque comment covering the whole block --
    #      "<iframe></iframe>kept" loses "kept" too, because CommonMark treats
    #      it as a single HTML block with no separate node for the trailing
    #      text -- and GFM's tagfilter extension only masks a fixed tag-name
    #      blocklist by escaping a single `<`, leaving any text a disallowed
    #      tag wraps, e.g. <script>, fully intact). Neither failure mode is
    #      acceptable here, so this layer's job is narrowed to turning
    #      Markdown into well-formed HTML, not to sanitizing it.
    #   2. SafeListSanitizer(prune: true) is therefore the actual security
    #      boundary: an explicit tag/attribute allowlist, and PRUNE rather
    #      than the default strip -- a disallowed element is removed
    #      together with its content, not just unwrapped, so a stripped
    #      <script>'s own text can't survive as inert-looking page copy.
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
        # unsafe: true hands raw HTML in the source to Nokogiri as real
        # elements rather than letting commonmarker mangle it itself --
        # sanitize(prune: true) below is what actually neutralises it.
        render: {unsafe: true},
        extension: {
          # header_ids: nil suppresses commonmarker's default anchor
          # injection. With it on, every heading gets
          # <a href="#slug" class="anchor"></a>; the sanitizer drops class
          # but keeps href, leaving an empty link inside every heading.
          header_ids: nil,
          table: true,
          strikethrough: true,
          autolink: true,
          # tagfilter would otherwise pre-empt the sanitizer for its own
          # fixed tag-name blocklist (script, iframe, style, ...) by
          # escaping just the `<`, leaving the disallowed tag as inert text
          # that sanitize(prune: true) never sees as an element and so can't
          # prune -- the tag's own text (e.g. a <script>'s body) would
          # survive as visible page copy.
          tagfilter: false
        }
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
        Rails::HTML5::SafeListSanitizer.new(prune: true)
          .sanitize(html, tags: ALLOWED_TAGS, attributes: ALLOWED_ATTRIBUTES)
          .html_safe
      end
    end
  end
end
