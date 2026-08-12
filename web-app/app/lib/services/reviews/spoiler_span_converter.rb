module Services
  module Reviews
    # One-shot conversion of the spoiler spans BodySanitizer.call used to generate on
    # write into the ||marker|| syntax it now stores. Used by the migration that runs
    # before the render change serves traffic.
    #
    # Parser-based, like everything else that touches this markup: children are moved
    # out of the span in place, never rebuilt from `.text`, so a spoiler wrapping a
    # <br> or an inline tag (<i>, <a>, ...) keeps its structure instead of collapsing
    # every line/element into one run-on string. See .convert_span for the one case
    # (a block-level descendant) that still has to flatten.
    #
    # PRECONDITION: the span's own text must not already contain "||". This class pairs
    # the two markers it inserts with nothing smarter than "one before, one after" --
    # a source "||" inside the span's text would unbalance that pairing and can leak
    # the spoiler at render time. Verified against all 119 real rows: none hit this.
    # Documented because this converter is a plausible reuse site (Task 7) where that
    # guarantee may not hold.
    class SpoilerSpanConverter
      SPOILER_CLASS = BodySanitizer::SPOILER_CLASS
      # Same list BodySanitizer#render partitions spoiler-marker search scopes on. A
      # block-level descendant here needs the flattening fallback below -- see
      # .convert_span.
      BLOCK_BOUNDARY_TAGS = BodySanitizer::SPOILER_SCOPE_BOUNDARY_TAGS

      def self.call(html)
        return nil if html.nil?

        fragment = Nokogiri::HTML5.fragment(html.to_s)
        spans = fragment.css("span.#{SPOILER_CLASS}").to_a
        return html.to_s if spans.empty?

        spans.each { |span| convert_span(span, fragment.document) }
        fragment.to_html
      end

      # Unwraps one span: its children move out to where the span was, sandwiched
      # between two literal "||" text nodes, so a <br> or an inline tag inside stays
      # exactly what it was -- only the span wrapper is gone.
      #
      # A span with a block-level descendant (p or blockquote -- BLOCK_BOUNDARY_TAGS)
      # cannot go through that path: a block element is a spoiler SCOPE boundary at
      # render time (see BodySanitizer#convert_spoiler_scope), so the "||" this would
      # place before it and the "||" placed after it end up in two different search
      # scopes and never pair up -- everything after the block child would render in
      # the clear instead of inside a spoiler. Falls back to flattening the whole span
      # to `.text` instead: that loses this span's internal formatting (its own <br>s,
      # its blockquote's structure), but the result is one text run with both markers
      # in the same scope, so it stays hidden. Reachable with real data: one of the
      # 119 rows has a <blockquote> nested inside its spoiler span.
      def self.convert_span(span, document)
        if span.css(BLOCK_BOUNDARY_TAGS.join(",")).any?
          span.replace(Nokogiri::XML::Text.new("||#{span.text}||", document))
          return
        end

        span.add_previous_sibling(Nokogiri::XML::Text.new("||", document))
        # .to_a snapshots the child list before mutating it -- add_previous_sibling
        # reparents each child as it runs, and each new insertion lands immediately
        # before the (still-present) span, i.e. right after the previous insertion,
        # so original child order is preserved.
        span.children.to_a.each { |child| span.add_previous_sibling(child) }
        span.add_previous_sibling(Nokogiri::XML::Text.new("||", document))
        span.remove
      end
      private_class_method :convert_span
    end
  end
end
