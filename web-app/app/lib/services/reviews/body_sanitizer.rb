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

      # Spoilers are written as ||like this||. Measured against the corpus before
      # choosing it: 0 existing bodies contain "||", 7 contain ">!", so the Discord
      # delimiter is collision-free here and the Reddit one is not.
      #
      # Non-greedy and multiline: a body with two spoilers must produce two spans, not
      # one span swallowing everything between the first and last marker, and a spoiler
      # may span a newline inside a paragraph.
      SPOILER_MARKER = "||".freeze
      SPOILER_PATTERN = /\|\|(.+?)\|\|/m

      # Guards .call's newline-to-paragraph conversion (see #paragraphize). Matches an
      # opening p/br/blockquote/pre tag anywhere in the raw body -- good enough to
      # detect "this body already has real paragraph structure" without a full parse,
      # and every migrated row has one because ReviewMigrator ran legacy
      # WYSIWYG-authored HTML through this same .call. `pre` is included even though it
      # is not in ALLOWED_TAGS (the sanitizer strips it same as always) purely so
      # paragraphize does not blank-line-split the preformatted text inside it and
      # splice <p> tags across the boundary before the sanitizer ever sees it.
      BLOCK_MARKUP = %r{<(?:p|br|blockquote|pre)[\s/>]}i

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

      # Inverse of .call, for ReviewStateController#serialize -- both what .call does to
      # a written <spoiler> (see convert_spoilers) and what it does to blank-line-
      # separated plain text (see #paragraphize), so the edit textarea shows what the
      # author actually typed rather than markup .call generated from it. Getting only
      # the spoiler half right is not enough: a stored "<p>Line one.</p><p>Line
      # two.</p>" handed back with its <p> tags intact would show the author literal
      # tags they never typed, and re-saving it verbatim would hit the BLOCK_MARKUP
      # guard on the next .call and skip paragraph conversion entirely, so a newly
      # typed blank line would survive as a bare "\n\n" and render as one run-on line.
      #
      # The paragraph half only reverses when doing so is PROVABLY safe -- see
      # #restore_paragraphs for how "safe" is decided and why a migrated body's real
      # <p>/<br> structure (never written by paragraphize) is not mistaken for it.
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
          paragraphize(@body.to_s),
          tags: RENDER_TAGS,
          attributes: RENDER_ATTRIBUTES
        ).to_s

        fragment = Nokogiri::HTML5.fragment(sanitized)
        scrub_classes(fragment)
        convert_spoiler_markers(fragment)
        harden_links(fragment)
        # Safe to mark: everything in the buffer came out of the sanitizer above, and
        # convert_spoiler_markers escapes every character it did not itself emit.
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
        restore_spoiler_tags(fragment)
        restore_paragraphs(fragment) || fragment.to_html
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

      # for_editing's half of convert_spoilers, run in place on an already-parsed
      # fragment instead of returning a new one -- restore_paragraphs (below) needs to
      # see these nodes as <spoiler> too, since that is what the author typed and what
      # paragraph_source must put back into the reversed text.
      def restore_spoiler_tags(fragment)
        fragment.css("span.#{SPOILER_CLASS}").each do |node|
          node.name = SPOILER_TAG
          node.attributes.keys.each { |name| node.remove_attribute(name) }
        end
      end

      # Inverse of #paragraphize, but only ever offered when reconverting the result
      # reproduces this exact stored body -- see the long comment on #for_editing for
      # why getting this wrong is the whole risk here.
      #
      # There is no marker on the stored HTML saying "paragraphize wrote this p tag";
      # <p>Line one.</p><p>Line two.</p> looks identical whether .call generated it from
      # "Line one.\n\nLine two." or a migrated row's legacy HTML happened to already be
      # exactly that. Telling them apart by INSPECTING the markup would mean duplicating
      # every detail of what paragraphize can and cannot produce, and staying right
      # forever as that method changes. Telling them apart by SIMULATING is simpler and
      # self-updating: build the candidate blank-line text this fragment would have come
      # from, run it back through the real .call, and compare. paragraphize is a pure
      # function of its input string, so anything it actually wrote reverses and
      # reconverts losslessly; anything it did NOT write (BLOCK_MARKUP guarded it off,
      # or a human hand-typed real tags) generally does not, because .call never emits a
      # bare text/br node outside a <p> and never removes a raw newline that was sitting
      # inside a tag it left untouched. Nil on any mismatch, so paragraphize itself is
      # never called against arbitrary parsed structure that might not actually be
      # blank-line-separated text -- only the one candidate .call already agrees with.
      #
      # Guarded to the exact shape paragraphize can produce -- fragment's top level is
      # one or more <p> elements and nothing else -- so structure that plainly isn't
      # paragraphize's output (bare top-level text, a bare <br>, a <blockquote>) is
      # rejected up front without needing the round trip to prove it.
      def restore_paragraphs(fragment)
        top_level = fragment.children
        return nil if top_level.empty?
        return nil unless top_level.all? { |node| node.element? && node.name == "p" }

        candidate = top_level.map { |p| paragraph_source(p) }.join("\n\n")
        return nil if self.class.call(candidate) != @body.to_s

        candidate
      end

      # A <p>'s content, with each <br> child turned back into the newline it came from
      # and every other child (text, or an inline tag like the restored <spoiler>)
      # serialized as-is -- paragraphize never looked inside a block, it only split and
      # wrapped, so nothing here needs to either.
      def paragraph_source(p)
        p.children.map { |child| (child.name == "br") ? "\n" : child.to_html }.join
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

      # Walks TEXT NODES ONLY. An attribute value is not a text node, so
      # <a href="||evil||"> cannot receive a spliced span -- the exact failure this
      # file's header documents from the original string-substitution attempt, avoided
      # the same way, just running in the other direction.
      #
      # Text either side of a marker pair is escaped before being reparsed, so nothing
      # a user typed can become markup: the ONLY element this introduces is the span
      # written here.
      #
      # Collected before mutating: replacing a node while traversing the same live
      # NodeSet is undefined.
      def convert_spoiler_markers(fragment)
        text_nodes = fragment.xpath(".//text()").to_a
        text_nodes.each do |node|
          content = node.content
          next unless content.include?(SPOILER_MARKER)
          next unless content.match?(SPOILER_PATTERN)

          node.replace(Nokogiri::HTML5.fragment(spoiler_html_for(content)))
        end
      end

      # String#split against a pattern with ONE capture group interleaves the captures
      # into the result, so even indices are the literal text between markers and odd
      # indices are the spoiler contents. That avoids hand-tracking match offsets, and
      # it makes the escaping rule obvious: everything gets escaped, and the only
      # element emitted is the span written here.
      #
      # The -1 limit keeps a trailing empty field, so a body ending in a spoiler does
      # not silently lose the (empty) text after it.
      def spoiler_html_for(content)
        content.split(SPOILER_PATTERN, -1).each_with_index.map { |part, index|
          if index.odd?
            %(<span class="#{SPOILER_CLASS}">#{CGI.escapeHTML(part)}</span>)
          else
            CGI.escapeHTML(part)
          end
        }.join
      end
    end
  end
end
