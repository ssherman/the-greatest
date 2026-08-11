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

      # Guards .call's newline-to-paragraph conversion (see #paragraphize). Matches an
      # opening p/br/blockquote tag anywhere in the raw body -- good enough to detect
      # "this body already has real paragraph structure" without a full parse, and every
      # migrated row has one because ReviewMigrator ran legacy WYSIWYG-authored HTML
      # through this same .call.
      BLOCK_MARKUP = %r{<(?:p|br|blockquote)[\s/>]}i

      # The render-time allowlist. It is NOT the write-time one, and the two must stay
      # in this file together so they cannot drift apart in review.
      #
      # `span` is absent from the write list on purpose -- that is what stops a user
      # supplying their own review-spoiler class. Stored bodies, however, already
      # contain the spans this class produced, so the render pass has to let them
      # through. Re-running .call on stored output instead would strip all 118
      # production spoiler wrappers and print their contents in the clear.
      RENDER_TAGS = (ALLOWED_TAGS + %w[span]).freeze

      # NOT ALLOWED_ATTRIBUTES + class -- the two lists are no longer related by
      # addition. `title` is dropped: it's decorative, and on a spoiler span it would
      # leak the spoiler text through the browser's native tooltip, the exact leak
      # .call strips attributes to prevent. `class` is admitted only so a stored
      # spoiler span's class can survive the sanitize pass, which applies `attributes:`
      # globally rather than per-tag -- scrub_classes then narrows that blanket
      # allowance down to exactly SPOILER_CLASS on a span and removes it everywhere
      # else, so no other class value (including ones matching compiled utility
      # classes like `.fixed`/`.inset-0`/`.z-50`) reaches the page.
      RENDER_ATTRIBUTES = %w[href class].freeze
      LINK_REL = "nofollow ugc noopener".freeze

      def self.call(body)
        new(body).call
      end

      # Sanitizes again on the way out -- the stored body was cleaned on write, but a
      # second pass costs one parse on a page that renders at most 37 reviews and means
      # no single bug can put markup on the page.
      def self.render(body)
        return nil if body.blank?

        new(body).render
      end

      # Inverse of convert_spoilers, for ReviewStateController#serialize. A stored body
      # already contains <span class="review-spoiler">, which is what .call turned a
      # written <spoiler> into -- span is absent from .call's own write-time tag
      # allowlist (see RENDER_TAGS's comment), so feeding a stored body back into .call
      # strips the span tag on the next save and leaves the spoiler as plain, public
      # text. This restores <spoiler> so the edit textarea shows what the author
      # actually typed, rather than the raw <span> markup, and so a re-save round-trips
      # through .call correctly instead of destroying the spoiler.
      def self.for_editing(body)
        return nil if body.blank?

        new(body).for_editing
      end

      def initialize(body)
        @body = body
      end

      def call
        return nil if @body.blank?

        sanitized = sanitizer.sanitize(
          paragraphize(@body.to_s),
          tags: ALLOWED_TAGS + [SPOILER_TAG],
          attributes: ALLOWED_ATTRIBUTES
        ).to_s

        fragment = convert_spoilers(sanitized)
        return nil if blank_text?(fragment)

        fragment.to_html
      end

      def render
        sanitized = sanitizer.sanitize(
          @body.to_s,
          tags: RENDER_TAGS,
          attributes: RENDER_ATTRIBUTES
        ).to_s

        fragment = Nokogiri::HTML5.fragment(sanitized)
        scrub_classes(fragment)
        harden_links(fragment)
        # Safe to mark: everything in the buffer just came out of the sanitizer above.
        fragment.to_html.html_safe # rubocop:disable Rails/OutputSafety
      end

      # HTML-parsed, not string substitution, for the same reason .call itself is (see
      # this file's header comment): a marker robust enough to survive naive replacement
      # also survives inside a quoted attribute value on some other tag, and splicing
      # raw markup into a quoted string re-parses into something a browser reads
      # completely differently. That reasoning applies just as much running in reverse.
      #
      # Plain string, not html_safe -- this is going into a JSON API response and then a
      # <textarea>'s plain-text value, never rendered as HTML.
      def for_editing
        return nil if @body.blank?

        fragment = Nokogiri::HTML5.fragment(@body.to_s)
        fragment.css("span.#{SPOILER_CLASS}").each do |node|
          node.name = SPOILER_TAG
          node.attributes.keys.each { |name| node.remove_attribute(name) }
        end
        fragment.to_html
      end

      private

      def sanitizer
        @sanitizer ||= Rails::HTML5::SafeListSanitizer.new
      end

      # A plain-text body arrives with nothing but newlines -- a browser renders a bare
      # "\n" as nothing at all, so without this a multi-paragraph review collapses into
      # one run-on line (.review-body styles `p + p` but has no `white-space` rule to
      # fall back on). Guarded on BLOCK_MARKUP so a body that already has real paragraph
      # structure -- every migrated row does -- passes through untouched instead of
      # having its existing tags' internal newlines reinterpreted. Also a no-op with no
      # newline at all: a single line with nothing to convert is left exactly as every
      # other test in this file already pins it (a bare <spoiler> tag, a bare <a>, ...),
      # not wrapped in a <p> it never asked for.
      #
      # A blank-line-separated run becomes a <p>; a lone newline inside a run becomes a
      # <br>, mirroring what the textarea's own newlines mean to whoever typed them.
      def paragraphize(text)
        return text if text.match?(BLOCK_MARKUP)
        return text unless text.match?(/\r|\n/)

        normalized = text.gsub(/\r\n?/, "\n")
        normalized.split(/\n[ \t]*\n+/).filter_map do |block|
          stripped = block.strip
          next if stripped.empty?

          "<p>#{stripped.gsub("\n", "<br>")}</p>"
        end.join
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

      # RENDER_ATTRIBUTES admits `class` on every tag, not just span, because the
      # sanitizer applies `attributes:` globally rather than per-tag. This narrows that
      # blanket allowance to exactly SPOILER_CLASS on a span and drops class everywhere
      # else, so an attacker-supplied class (e.g. one matching a compiled utility class
      # like `.fixed`/`.inset-0`/`.z-50`) never reaches the page.
      def scrub_classes(fragment)
        fragment.css("[class]").each do |node|
          if node.name == "span" && node["class"].to_s.split.include?(SPOILER_CLASS)
            node["class"] = SPOILER_CLASS
          else
            node.remove_attribute("class")
          end
        end
      end

      # Review bodies are untrusted, and this domain has ~156k indexed URLs. Applied at
      # render rather than on write because all 141,869 migrated rows -- 119 of them
      # carrying an <a> -- were written before this existed.
      def harden_links(fragment)
        fragment.css("a").each do |node|
          node["rel"] = LINK_REL
          node["target"] = "_blank"
        end
      end
    end
  end
end
