module Services
  module Reviews
    # Single implementation of review-body cleaning. Called from Review's
    # before_validation and directly by the increment-2 migrator, which bulk-inserts
    # and so bypasses callbacks.
    #
    # Spoilers are resolved by the HTML parser, never by string substitution. `spoiler`
    # is allowlisted for the sanitize pass so a genuine <spoiler> becomes a real node,
    # then those nodes are renamed. Text that merely looks like a spoiler tag inside an
    # attribute value is escaped by the parser and never becomes a node.
    #
    # Do NOT go back to tokenizing the string and substituting after sanitizing. Any
    # marker robust enough to survive sanitizing also survives inside an attribute
    # value, so the substitution splices raw markup into a quoted string:
    # `<a href="<spoiler>evil</spoiler>">click</a>` became
    # `<a href="<span class="review-spoiler">evil</span>">click</a>`, which a browser
    # re-parses into a bogus href and visible link text of `evil">click`.
    #
    # Renaming after sanitizing is also what stops a user supplying their own class:
    # `span` is not in ALLOWED_TAGS, so a user-written <span class="review-spoiler"> is
    # stripped, and a class on their own <spoiler> is replaced with ours -- every other
    # attribute (title, href, ...) is stripped from the node too, or a native browser
    # tooltip would leak the spoiler text right through the blur.
    #
    # Blank is decided on rendered TEXT, not on the markup string -- "<br>", "<p></p>",
    # an empty <a href>, and a lone &nbsp; all sanitize to non-empty markup that
    # visually renders as nothing. `fragment.text` is matched against BLANK_TEXT after
    # convert_spoilers, which returns the parsed fragment rather than re-serializing it,
    # so there is only one parse. This subsumes the plain <img>-only case, since `img`
    # is not in the allowlist and so contributes no text either.
    #
    # BLANK_TEXT must stay Unicode-aware. String#strip removes only ASCII whitespace, so
    # a body of &nbsp;, &emsp; (U+2003), &thinsp; (U+2009) or an ideographic space
    # (U+3000) would otherwise persist and be counted by `with_body` and
    # text_reviews_count while rendering as nothing. The POSIX [[:space:]] class covers
    # all of those; the zero-width characters listed alongside it (U+200B-U+200D, U+FEFF)
    # are NOT Unicode whitespace but render as nothing just the same.
    #
    # Does not truncate. Length is a Review validation, so an over-long paste raises a
    # user-visible error instead of losing text.
    class BodySanitizer
      ALLOWED_TAGS = %w[p br a i b em strong blockquote].freeze
      ALLOWED_ATTRIBUTES = %w[href title].freeze
      SPOILER_TAG = "spoiler".freeze
      SPOILER_CLASS = "review-spoiler".freeze
      BLANK_TEXT = /\A[[:space:]\u200B-\u200D\uFEFF]*\z/

      def self.call(body)
        new(body).call
      end

      def initialize(body)
        @body = body
      end

      def call
        return nil if @body.blank?

        sanitized = sanitizer.sanitize(
          @body.to_s,
          tags: ALLOWED_TAGS + [SPOILER_TAG],
          attributes: ALLOWED_ATTRIBUTES
        ).to_s

        fragment = convert_spoilers(sanitized)
        return nil if blank_text?(fragment)

        fragment.to_html
      end

      private

      def sanitizer
        @sanitizer ||= Rails::HTML5::SafeListSanitizer.new
      end

      def convert_spoilers(html)
        fragment = Nokogiri::HTML5.fragment(html)
        fragment.css(SPOILER_TAG).each do |node|
          node.name = "span"
          node.attributes.keys.each { |name| node.remove_attribute(name) }
          node["class"] = SPOILER_CLASS
        end
        fragment
      end

      def blank_text?(fragment)
        fragment.text.match?(BLANK_TEXT)
      end
    end
  end
end
