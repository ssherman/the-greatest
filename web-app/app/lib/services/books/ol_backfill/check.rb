# frozen_string_literal: true

module Services
  module Books
    module OlBackfill
      # Spec section 1, "The title-and-author check": both passes act on an
      # Open Library work only when it agrees with our book on its title and
      # on at least one author.
      module Check
        module_function

        COMPACT_MIN = 4
        AUTHOR_FETCH_LIMIT = 5

        def agree?(book, work, ol_authors: [])
          titles_agree?(book, work) && authors_agree?(book, work, ol_authors: ol_authors)
        end

        # agree?, fetching the work's author records from Open Library (once,
        # at most AUTHOR_FETCH_LIMIT) only when the title agrees and the names
        # on the work do not.
        def verified?(book, work, client)
          return false unless titles_agree?(book, work)
          return true if authors_agree?(book, work)

          keys = Array(work.author_keys).compact.first(AUTHOR_FETCH_LIMIT)
          return false if keys.empty?

          authors_agree?(book, work, ol_authors: client.authors_batch(keys).values.compact)
        end

        # Neither the title nor any author agrees: another book's record. Fetches
        # the work's author records (once, at most AUTHOR_FETCH_LIMIT) only when
        # the title and the names on the work both fail.
        def clearly_different?(book, work, client)
          return false if titles_agree?(book, work) || authors_agree?(book, work)

          keys = Array(work.author_keys).compact.first(AUTHOR_FETCH_LIMIT)
          return true if keys.empty?

          !authors_agree?(book, work, ol_authors: client.authors_batch(keys).values.compact)
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

        # Any of: a shared normalized name; a shared "compact" name (letters
        # only, so "J.R.R. Tolkien" is "J. R. R. Tolkien"); one of our authors
        # holding a key the work lists; one of our names matching the name or
        # an alternate name of the work's Open Library author records.
        def authors_agree?(book, work, ol_authors: [])
          authors = book.authors.to_a
          names = authors.flat_map { |author| [author.name, *Array(author.alternate_names)] }
          ours = names.filter_map { |name| normalize(name) }
          ours_compact = names.filter_map { |name| compact(name) }
          theirs_names = Array(work.author_names)
          return true if ours.intersect?(theirs_names.filter_map { |name| normalize(name) })
          return true if ours_compact.intersect?(theirs_names.filter_map { |name| compact(name) })
          return true if holds_author_key?(authors, work)

          record_names = ol_authors.flat_map { |author| [author.name, *Array(author.alternate_names)] }
          ours.intersect?(record_names.filter_map { |name| normalize(name) }) ||
            ours_compact.intersect?(record_names.filter_map { |name| compact(name) })
        end

        def holds_author_key?(authors, work)
          keys = Array(work.author_keys).compact
          return false if keys.empty? || authors.empty?

          ::Identifier.where(identifiable_type: "Books::Author", identifiable_id: authors.map(&:id),
            identifier_type: :books_author_openlibrary_id, value: keys).exists?
        end

        # Lowercase letters only, diacritics stripped; nil when too short to mean anything.
        def compact(text)
          return nil if text.blank?

          letters = text.to_s.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase.gsub(/[^\p{L}]/, "")
          letters if letters.length >= COMPACT_MIN
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
