module Services
  module Reviews
    # Single implementation of review-body cleaning. Called from Review's
    # before_validation and directly by the increment-2 migrator, which bulk-inserts
    # and so bypasses callbacks.
    #
    # ||spoiler|| markers are resolved by the HTML parser at render time, never by
    # string substitution -- see #render and convert_spoiler_markers below. .call
    # itself does not treat `spoiler` as special: a literal <spoiler> tag, whether
    # hand-typed or left over from before this method generated them itself, is
    # unwrapped like any other disallowed tag -- its text survives, the tag does not.
    #
    # Do NOT go back to tokenizing a string and substituting into it after sanitizing.
    # Any marker robust enough to survive sanitizing also survives inside an attribute
    # value, so the substitution splices raw markup into a quoted string:
    # `<a href="<spoiler>evil</spoiler>">click</a>` became
    # `<a href="<span class="review-spoiler">evil</span>">click</a>`, which a browser
    # re-parses into a bogus href and visible link text of `evil">click`. That was
    # this file's original write-time <spoiler>-to-<span> conversion; the same
    # reasoning is why #render's marker conversion also walks parsed text nodes
    # instead of substituting into the raw string.
    #
    # `span` and `spoiler` are both absent from .call's tags on purpose: a user-written
    # <span class="review-spoiler"> or <spoiler title="secret"> is unwrapped like any
    # other disallowed tag -- the tag AND every attribute on it are dropped, only its
    # text content survives. That is what stops a user supplying their own spoiler
    # class or smuggling a title through; on a real spoiler span a title would leak the
    # hidden text right through the browser's native tooltip (see RENDER_ATTRIBUTES for
    # the render-time half of that same defense).
    #
    # Blank is decided on rendered TEXT, not on the markup string -- "<br>", "<p></p>",
    # an empty <a href>, and a lone &nbsp; all sanitize to non-empty markup that
    # visually renders as nothing. `fragment.text` is matched against BLANK_TEXT on the
    # already-parsed fragment rather than re-serializing it first, so there is only one
    # parse. This subsumes the plain <img>-only case, since `img` is not in the
    # allowlist and so contributes no text either.
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
      SPOILER_CLASS = "review-spoiler".freeze
      BLANK_TEXT = /\A[[:space:]\u200B-\u200D\uFEFF]*\z/

      # Spoilers are written as ||like this||. Measured against the corpus before
      # choosing it: 0 existing bodies contain "||", 7 contain ">!", so the Discord
      # delimiter is collision-free here and the Reddit one is not.
      #
      # Non-greedy: a body with two spoilers must produce two spans, not one span
      # swallowing everything between the first and last marker. Multiline (/m) so `.`
      # matches a literal newline WITHIN one text node's content -- but how far a
      # match is actually allowed to reach (a single <br>, a whole inline tag, never
      # a paragraph boundary) is decided by convert_spoiler_markers below, not by
      # this pattern alone.
      SPOILER_MARKER = "||".freeze
      SPOILER_PATTERN = /\|\|(.+?)\|\|/m

      # A spoiler match must never straddle two different paragraphs, so a search
      # scope is cut at every p/blockquote SIBLING encountered while walking the
      # tree (see convert_spoiler_scope). This is NOT a guarantee that a p or
      # blockquote can never end up inside one scope's search text by some other
      # route: convert_spoiler_run pulls text through EVERY descendant of a
      # non-boundary node via `.//text()`, so a <p> nested inside an inline tag --
      # e.g. "<b>||a<p>mid</p>b||</b>", which real HTML5 parsing allows -- is
      # reached and can be moved into a spoiler span along with everything else in
      # that <b>. Harmless in practice (no injection, and a browser still renders
      # the nesting), just not something this list alone rules out.
      SPOILER_SCOPE_BOUNDARY_TAGS = %w[p blockquote].freeze

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

      def initialize(body)
        @body = body
      end

      # Sanitizes. Does NOT transform.
      #
      # Every markup transformation lives in #render instead, so what is stored is what
      # the author typed: ||spoilers|| as literal text, paragraphs as newlines. That
      # makes this method idempotent, and an idempotent write path is what makes the
      # round-trip bug class unrepresentable -- converting on write produced markup this
      # method's own allowlist rejects, so every edit path had to un-convert first, and
      # three separate production-class defects came out of that. Do not reintroduce a
      # transformation here.
      def call
        return nil if @body.blank?

        sanitized = sanitizer.sanitize(
          @body.to_s,
          tags: ALLOWED_TAGS,
          attributes: ALLOWED_ATTRIBUTES
        ).to_s

        fragment = Nokogiri::HTML5.fragment(sanitized)
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
        # convert_spoiler_markers only ever moves existing nodes or builds new
        # Nokogiri::XML::Text nodes (auto-escaped by Nokogiri on serialization) --
        # never a string that gets reparsed as markup.
        fragment.to_html.html_safe # rubocop:disable Rails/OutputSafety
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

      # Entry point: partitions the fragment into independent search scopes at every
      # p/blockquote boundary (see SPOILER_SCOPE_BOUNDARY_TAGS) before matching a
      # single marker pair, so a spoiler can never merge two different paragraphs
      # into one giant span even when the raw text technically contains a pair of
      # markers straddling them -- that is a defensible scope limit (Discord
      # behaves the same way: a spoiler does not survive a paragraph break), not
      # an oversight. It also avoids a subtler failure: String#scan does not
      # backtrack past a match it already consumed, so without this partition a
      # stray unpaired "||" left over in one paragraph could swallow a LATER
      # paragraph's own legitimate pair as its closing delimiter, silently
      # breaking that second, unrelated spoiler.
      def convert_spoiler_markers(fragment)
        convert_spoiler_scope(fragment.children.to_a, fragment.document)
      end

      # Walks one level of siblings, accumulating a "run" of everything that is NOT
      # a scope boundary (plain text and inline elements -- br, a, i, b, em, strong,
      # an already-existing spoiler span) and flushing it through
      # convert_spoiler_run as one shared search scope. Hitting a boundary tag
      # flushes the current run and recurses into that element's own children,
      # which start a fresh, independent partition of runs one level down.
      def convert_spoiler_scope(siblings, document)
        run = []
        siblings.each do |node|
          if node.element? && SPOILER_SCOPE_BOUNDARY_TAGS.include?(node.name)
            convert_spoiler_run(run, document)
            run = []
            convert_spoiler_scope(node.children.to_a, document)
          else
            run << node
          end
        end
        convert_spoiler_run(run, document)
      end

      # One scope's worth of matching. TEXT NODES ONLY, gathered from every node in
      # `nodes` (recursing into an inline element's own descendants, so nested
      # formatting like <b><i>text</i></b> is reachable too) and concatenated into
      # one string, so SPOILER_PATTERN can match ACROSS node boundaries: a marker
      # either side of a <br> (a single typed newline, once paragraphize has turned
      # it into an element) or wrapped around a whole inline element
      # (||He <b>dies</b> at the end||) is found here, not just a marker sitting
      # inside a single node.
      #
      # An attribute value is never part of `combined` -- it is not reachable via
      # `.//text()` at all, regardless of how far matching reaches across siblings
      # -- so <a href="||evil||"> cannot receive a spliced span. That is the exact
      # failure this file's header documents from the original string-substitution
      # attempt, avoided the same way it always was: never treat serialized markup,
      # or anything that could contain it, as a plain string to search and replace.
      def convert_spoiler_run(nodes, document)
        return if nodes.empty?

        text_nodes = nodes.flat_map { |node| node.text? ? [node] : node.xpath(".//text()").to_a }
        return if text_nodes.empty?

        contents = text_nodes.map(&:content)
        combined = contents.join
        return unless combined.include?(SPOILER_MARKER)

        matches = combined.to_enum(:scan, SPOILER_PATTERN).map { Regexp.last_match }
        return if matches.empty?

        starts = spoiler_node_offsets(contents)

        # Reverse: converting a match only ever truncates its start/end node from
        # the right and inserts new siblings after it, so an earlier (leftward)
        # match's node references and offsets are never invalidated by processing
        # a later one first.
        matches.reverse_each { |match| convert_spoiler_match(document, text_nodes, starts, contents, match) }
      end

      def spoiler_node_offsets(contents)
        offsets = []
        position = 0
        contents.each do |content|
          offsets << position
          position += content.length
        end
        offsets
      end

      def spoiler_node_index(offsets, contents, char_position)
        offsets.each_index do |index|
          return index if char_position < offsets[index] + contents[index].length
        end
        offsets.length - 1
      end

      # Rewraps exactly one match. Same node on both ends is the common case (a
      # marker pair sitting inside one run of plain text); different nodes means
      # the match reaches across one or more inline elements (or a <br>), which
      # are moved into the new span WHOLE via `add_child` -- never touched, never
      # re-escaped -- so a real <b> stays a real, functioning <b> inside the
      # spoiler, the same way it would outside one.
      #
      # Requires start and end to be direct siblings: `next_sibling` is how the
      # in-between nodes are located and moved. A match whose start and end sit at
      # different depths is left unconverted rather than guessed at -- a narrower,
      # defensible limit, not silent corruption. This IS reachable with ordinary
      # allowed-tag typing, not just a theoretical shape: a body stored as
      # "<b>||He dies</b> at the end||" (opening marker inside a <b>, closing
      # marker outside it) has its "||" delimiters in nodes with different
      # parents, and is left exactly as typed -- visibly leaking the marker text
      # rather than hiding it. Structurally safe (nothing corrupts), but it
      # reintroduces the exact leak spoiler conversion exists to close. Known and
      # accepted for now; a future task could widen this by walking up to a
      # shared ancestor and moving partial subtrees on both sides, which this
      # method does not attempt.
      #
      # New text is built as real Nokogiri::XML::Text nodes, not by string-building
      # and reparsing: `.content` already returns fully-decoded text, and Nokogiri
      # re-encodes a Text node's content correctly on serialization, so nothing
      # needs manual escaping and nothing typed by a user can introduce a tag --
      # the only element this ever adds is the span constructed here.
      def convert_spoiler_match(document, text_nodes, starts, contents, match)
        start_index = spoiler_node_index(starts, contents, match.begin(0))
        end_index = spoiler_node_index(starts, contents, match.end(0) - 1)
        start_node = text_nodes[start_index]
        end_node = text_nodes[end_index]
        return if start_index != end_index && start_node.parent != end_node.parent

        # The "||" delimiter itself can straddle a node boundary (one pipe as the
        # last character of one node, the other as the first character of the
        # next -- an ordinary typed newline right between them does this once
        # paragraphize turns it into a <br>). When that happens, begin(1)/end(1)
        # -- the CAPTURED content's bounds -- can land outside start_index/end_index,
        # the nodes begin(0)/end(0) resolved to. Slicing against the wrong node's
        # offset in that situation is simply wrong: too large an offset returns nil
        # and crashes on `.empty?` (a 500 on a public page); too negative an offset
        # returns a wrong-but-non-nil slice, silently duplicating and losing text
        # instead of raising.
        #
        # The check is deliberately an INCLUSIVE range against `contents`, not
        # node-index equality (spoiler_node_index's half-open "< end" test) --
        # begin(1)/end(1) legitimately land EXACTLY on a node's own boundary
        # whenever the marker sits flush against a tag with no text in between
        # ("||<b>x</b>||", "The killer is ||<b>the butler</b>||"), and that boundary
        # position slices to a valid empty string, not an out-of-bounds one. A
        # stricter equality check here previously rejected those (and 119 of a
        # 15,817-input fuzz corpus with it) even though nothing about them was
        # unsafe -- an over-rejection, not a safety fix. This range only proves
        # SUFFICIENCY: it guarantees local_inner_start/local_inner_end land in
        # [0, contents[index].length], which is what the slice below needs against
        # `contents`' *lengths* -- it does not claim to be the unique condition
        # that would work, and it says nothing on its own about the LIVE
        # `.content` read next, which can be shorter than `contents[index]` if an
        # already-processed (rightward) match truncated this same node; that gap
        # is closed by the separate reverse-processing invariant noted below.
        start_length = contents[start_index].length
        return unless (starts[start_index]..starts[start_index] + start_length).cover?(match.begin(1))

        end_length = contents[end_index].length
        return unless (starts[end_index]..starts[end_index] + end_length).cover?(match.end(1))

        span = Nokogiri::XML::Node.new("span", document)
        span["class"] = SPOILER_CLASS

        local_outer_start = match.begin(0) - starts[start_index]
        local_inner_start = match.begin(1) - starts[start_index]
        local_inner_end = match.end(1) - starts[end_index]
        local_outer_end = match.end(0) - starts[end_index]

        # Live content, not the `contents` snapshot: an earlier (rightward) match
        # sharing this same node already truncated it, and reverse processing
        # guarantees the region this match touches was untouched by that.
        start_text = start_node.content
        end_text = end_node.content
        before = start_text[0...local_outer_start]

        if start_index == end_index
          span_text = start_text[local_inner_start...local_inner_end]
          after = start_text[local_outer_end..]

          span.add_child(Nokogiri::XML::Text.new(span_text, document)) unless span_text.empty?
          start_node.content = before
          start_node.add_next_sibling(span)
          span.add_next_sibling(Nokogiri::XML::Text.new(after, document)) unless after.empty?
        else
          between = []
          sibling = start_node.next_sibling
          while sibling && !sibling.equal?(end_node)
            between << sibling
            sibling = sibling.next_sibling
          end

          start_inside = start_text[local_inner_start..]
          end_inside = end_text[0...local_inner_end]
          after = end_text[local_outer_end..]

          span.add_child(Nokogiri::XML::Text.new(start_inside, document)) unless start_inside.empty?
          between.each { |sibling_node| span.add_child(sibling_node) }
          span.add_child(Nokogiri::XML::Text.new(end_inside, document)) unless end_inside.empty?

          start_node.content = before
          end_node.content = after
          start_node.add_next_sibling(span)
        end
      end
    end
  end
end
