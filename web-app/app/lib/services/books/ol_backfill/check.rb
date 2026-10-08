# frozen_string_literal: true

module Services
  module Books
    module OlBackfill
      # Spec section 1, "The title-and-author check": both passes act on an
      # Open Library work only when it agrees with our book on its title and
      # on at least one author.
      module Check
        module_function

        def agree?(book, work)
          titles_agree?(book, work) && authors_agree?(book, work)
        end

        # Equal after normalizing, or equal once a subtitle (text after the
        # first ":") is dropped from ONE side, never both: "Dune: Messiah"
        # and "Dune: Part One" do not agree. The work's own subtitle field,
        # when present, is its subtitle.
        def titles_agree?(book, work)
          ours = ([book.title] + Array(book.alternate_titles)).filter_map { |title| normalize(title) }.uniq
          theirs_full, theirs_short = their_titles(work)
          return false if ours.empty? || theirs_full.nil?

          ours_short = ours.filter_map { |title| short(title) }
          ours.include?(theirs_full) || (!theirs_short.nil? && ours.include?(theirs_short)) || ours_short.include?(theirs_full)
        end

        def authors_agree?(book, work)
          ours = book.authors.flat_map { |author| [author.name, *Array(author.alternate_names)] }.filter_map { |name| normalize(name) }
          theirs = Array(work.author_names).filter_map { |name| normalize(name) }
          ours.intersect?(theirs)
        end

        def normalize(text)
          return nil if text.blank?

          ::Services::Text::NameNormalizer.call(::Services::Text::QuoteNormalizer.call(text.to_s)).downcase.presence
        end

        # [full title, title without its subtitle (nil when there is none)].
        def their_titles(work)
          title = normalize(work.title)
          return [nil, nil] if title.nil?

          subtitle = normalize(work.subtitle)
          subtitle ? ["#{title}: #{subtitle}", title] : [title, short(title)]
        end

        def short(normalized)
          head, separator, = normalized.partition(":")
          head.strip.presence if separator.present?
        end
      end
    end
  end
end
