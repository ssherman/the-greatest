# frozen_string_literal: true

module Services
  module Books
    module GoodreadsEnrichment
      # Drops the search rows that clearly are not the book (spec §4.2) before
      # the cheap model sees them: another author, a study guide or omnibus,
      # or a title that does not contain ours. Deliberately loose on titles;
      # the pick and PageCheck do the fine work.
      class CandidateFilter
        def self.call(book:, rows:)
          new(book: book).call(rows)
        end

        # The three title/author tests, shared with PageCheck so the search
        # stage and the page stage cannot disagree on what a derivative or a
        # set is.
        # Words in the series parenthetical ("(The Border Trilogy, #1)") name the
        # series, not this book, so they are scanned only after it is stripped.
        # A numbered range there ("#1-3") is still an omnibus.
        def self.strip_series(title) = title.to_s.sub(::Books::Goodreads::BookPage::SERIES_SUFFIX, "")

        def self.derivative_free?(book, title)
          (AmazonBookCheck.derivative_words(strip_series(title)) - AmazonBookCheck.own_words(book, :derivative_words)).empty?
        end

        def self.set_free?(book, title)
          return false if title.to_s.match?(AmazonBookCheck::NUMBER_RANGE)

          (AmazonBookCheck.set_words(strip_series(title)) - AmazonBookCheck.own_words(book, :set_words)).empty?
        end

        def self.authors_agree?(book, names)
          Verification::Check.authors_agree?(book, AmazonBookCheck::Contributors.new(Array(names), []))
        end

        # Token sequences, not strings: "Catch-22" and "(Catch-22) By ..." both
        # reduce to a "catch 22" run however the punctuation falls. The trailing
        # series parenthetical goes first, so "Closing Time (Catch-22, #2)" is
        # not mistaken for the book it belongs to. Words are Check.title_key's:
        # accents folded and one leading article dropped on both sides, so "The
        # Lord of the Rings" finds "Lord of the Rings" and "Les Misérables" finds
        # "Les Miserables". Any of our titles will do: a book held under its
        # translated title still finds the row under the original.
        def self.title_contained?(book, row_title)
          theirs = tokens(strip_series(row_title))
          ([book.title] + Array(book.alternate_titles)).any? do |title|
            ours = tokens(title.to_s.split(":").first)
            ours.any? && theirs.each_cons(ours.size).include?(ours)
          end
        end

        def self.tokens(text)
          Verification::Check.title_key(text).to_s.split
        end

        def initialize(book:)
          @book = book
        end

        def call(rows)
          rows.select { |row| keep?(row) }
            .sort_by { |row| [-row.ratings_count.to_i, -row.editions_count.to_i] }
        end

        private

        def keep?(row)
          self.class.authors_agree?(@book, row.author_names) &&
            self.class.derivative_free?(@book, row.title) &&
            self.class.set_free?(@book, row.title) &&
            self.class.title_contained?(@book, row.title)
        end
      end
    end
  end
end
