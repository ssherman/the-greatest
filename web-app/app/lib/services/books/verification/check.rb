# frozen_string_literal: true

module Services
  module Books
    module Verification
      # Spec section 1, "The title-and-author check": both passes act on an
      # Open Library work only when it agrees with our book on its title and
      # on at least one author.
      module Check
        module_function

        COMPACT_MIN = 4
        AUTHOR_FETCH_LIMIT = 5

        # Letters NFKD leaves whole, folded to their plain-Latin spelling.
        FOLD = {
          "ø" => "o", "Ø" => "O", "æ" => "ae", "Æ" => "AE", "œ" => "oe", "Œ" => "OE",
          "ß" => "ss", "ẞ" => "SS", "đ" => "d", "Đ" => "D", "ł" => "l", "Ł" => "L",
          "þ" => "th", "Þ" => "TH"
        }.freeze
        FOLD_PATTERN = Regexp.union(FOLD.keys)
        LEADING_ARTICLES = %w[the a an le la les l el los las il lo i gli o os as der die das].freeze
        # A trailing parenthetical with any of these names a volume: never dropped.
        VOLUME_PARENTHETICAL = /\d|#|\b(vols?|volumes?|books?|part|tome)\b/i
        ROMAN_NUMERAL = /\A[ivxlcdm]+\z/i
        TRAILING_PARENTHETICAL = /\A(?<head>.*\S)\s*\((?<inside>[^()]*)\)\s*\z/

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

        # The title and the authors both disagree: another book's record.
        # Missing authors, on our side or the work's, are unknown, not
        # disagreement. Fetches the work's author records (once, at most
        # AUTHOR_FETCH_LIMIT) only when the title and the names on the work fail.
        def clearly_different?(book, work, client)
          return false if titles_agree?(book, work) || book.authors.empty?

          names = Array(work.author_names).reject(&:blank?)
          keys = Array(work.author_keys).compact.first(AUTHOR_FETCH_LIMIT)
          return false if names.empty? && keys.empty?
          return false if authors_agree?(book, work)

          records = keys.empty? ? [] : client.authors_batch(keys).values.compact
          return false if names.empty? && records.empty?

          !authors_agree?(book, work, ol_authors: records)
        end

        # Equal by title key, or equal once a subtitle (text after the first
        # ":") or a trailing edition parenthetical is dropped from ONE side,
        # never both: "Dune: Messiah" and "Dune: Part One" do not agree. The
        # work's own subtitle field, when present, is its subtitle.
        def titles_agree?(book, work)
          forms = ([book.title] + Array(book.alternate_titles)).map { |title| title_forms(title) }.reject { |full, _| full.nil? }
          theirs_full, theirs_short = their_title_keys(work)
          return false if forms.empty? || theirs_full.nil?

          ours = forms.map(&:first).uniq
          ours_short = forms.filter_map(&:last)
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

          letters = fold(text).downcase.gsub(/[^\p{L}]/, "")
          letters if letters.length >= COMPACT_MIN
        end

        def normalize(text)
          return nil if text.blank?

          ::Services::Text::NameNormalizer.call(::Services::Text::QuoteNormalizer.call(text.to_s)).downcase.presence
        end

        # Comparison key: normalized, letters folded, diacritics and punctuation
        # gone, one leading article dropped (never leaving it empty).
        def title_key(text)
          normalized = normalize(text)
          return nil if normalized.nil?

          words = fold(normalized).downcase.gsub(/[^\p{L}\p{M}\p{N} ]/, " ").split
          words.shift if words.length > 1 && LEADING_ARTICLES.include?(words.first)
          words.join(" ").presence
        end

        # [full key, key without a subtitle or edition parenthetical (nil when
        # there is none)]. Split before keying, while the punctuation is intact.
        def title_forms(text)
          normalized = normalize(text)
          return [nil, nil] if normalized.nil?

          full = title_key(normalized)
          match = TRAILING_PARENTHETICAL.match(normalized)
          if match
            inside = match[:inside]
            return [full, nil] if inside.match?(VOLUME_PARENTHETICAL) || inside.match?(EditionCheck::SET_WORDS) ||
              inside.strip.match?(ROMAN_NUMERAL)

            head = match[:head]
            return [full, title_key(head.include?(":") ? head.partition(":").first : head)]
          end

          head, separator, = normalized.partition(":")
          [full, (title_key(head) if separator.present?)]
        end

        # [full key, short key or nil] for an Open Library work; its subtitle
        # field, when present, is its subtitle.
        def their_title_keys(work)
          return [nil, nil] if normalize(work.title).nil?

          subtitle = normalize(work.subtitle)
          return title_forms(work.title) unless subtitle

          [title_key("#{normalize(work.title)}: #{subtitle}"), title_key(work.title)]
        end

        def fold(text)
          text.to_s.gsub(FOLD_PATTERN, FOLD).unicode_normalize(:nfkd).gsub(/\p{Mn}/, "")
        end
      end
    end
  end
end
