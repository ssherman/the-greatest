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
        def self.derivative_free?(book, title)
          (AmazonBookCheck.derivative_words(title) - AmazonBookCheck.own_words(book, :derivative_words)).empty?
        end

        def self.set_free?(book, title)
          (AmazonBookCheck.set_words(title) - AmazonBookCheck.own_words(book, :set_words)).empty?
        end

        def self.authors_agree?(book, names)
          Verification::Check.authors_agree?(book, AmazonBookCheck::Contributors.new(Array(names), []))
        end

        # Token sequences, not strings: "Catch-22" and "(Catch-22) By ..." both
        # reduce to a "catch 22" run however the punctuation falls. The trailing
        # series parenthetical goes first, so "Closing Time (Catch-22, #2)" is
        # not mistaken for the book it belongs to.
        def self.title_contained?(book, row_title)
          ours = tokens(book.title.to_s.split(":").first)
          theirs = tokens(row_title.to_s.sub(::Books::Goodreads::BookPage::SERIES_SUFFIX, ""))
          return false if ours.empty?

          theirs.each_cons(ours.size).include?(ours)
        end

        def self.tokens(text)
          Verification::Check.normalize(text).to_s.gsub(/[^\p{L}\p{N}]+/, " ").split
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
