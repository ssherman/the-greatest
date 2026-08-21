module Services
  module BooksMigration
    # Legacy ActionText (Trix) HTML -> Markdown, for the one-time blog migration.
    #
    # The whole legacy corpus is eight tags -- a, br, strong, h1, ul, ol, li,
    # div -- comfortably inside what reverse_markdown handles. Measured against
    # all 31 real posts, .call plus .round_trips? gives 31/31 text-identical.
    #
    # Root-anchored ::Services below is not needed because News is not nested
    # under BooksMigration, but note that a bare `Books::` inside this module
    # would resolve to Services::BooksMigration::Books and raise. Root-anchor
    # anything in the Books namespace.
    class NewsBodyConverter
      # reverse_markdown emits "**bold** :" for "<strong>bold</strong>:" -- it
      # inserts a space after a closing inline marker when punctuation follows
      # immediately. Narrowly targeted: only a marker directly followed by
      # " " + punctuation, so "a word : spaced" in ordinary prose is untouched.
      STRAY_SPACE = /(\*\*|\*|_|`) ([:;,.!?])/

      def self.call(html)
        return "" if html.blank?

        markdown = ReverseMarkdown.convert(
          html.to_s,
          unknown_tags: :bypass,
          github_flavored: true
        )

        markdown.gsub(STRAY_SPACE, '\1\2')
      end

      # Renders the produced Markdown back to HTML through the very renderer the
      # public page uses, and compares block-aware plain text against the legacy
      # HTML's. Catches content silently dropped by the conversion.
      #
      # Both sides go through Services::News::PlainText, which inserts a
      # separator at block boundaries -- comparing raw .text would flag every
      # multi-block post, because legacy wraps paragraphs in <div> and the
      # renderer emits <p>.
      def self.round_trips?(html)
        legacy = ::Services::News::PlainText.call(html)
        rendered = ::Services::News::PlainText.call(
          ::Services::News::BodyRenderer.call(call(html))
        )

        legacy == rendered
      end
    end
  end
end
