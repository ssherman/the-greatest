# frozen_string_literal: true

module Books
  module WorldCat
    # Our ISBN-13s, one per line, for the build's catalogue_coverage gate
    # (data-sources: `--catalogue-isbns`). Mirrors EvalExport's E2E-leftover filter.
    #
    # The WorldCat service rejects a whole batch if any ISBN fails its check digit, and
    # legacy identifier rows can carry invalid values. So only values that
    # Books::Isbn.normalize accepts are written, and the normalised isbn13 is written
    # rather than the raw value (which also collapses hyphenated and plain spellings).
    class IsbnExport
      def self.call(io:)
        new(io).call
      end

      def initialize(io)
        @io = io
      end

      # Returns the number of lines written.
      def call
        isbns = scope.distinct.pluck(:value).filter_map { |value| ::Books::Isbn.normalize(value)&.isbn13 }.uniq
        isbns.each { |isbn| @io.puts(isbn) }
        isbns.size
      end

      private

      def scope
        ::Identifier
          .where(identifiable_type: "Books::Book", identifier_type: :books_work_isbn13)
          .joins("INNER JOIN books_books ON books_books.id = identifiers.identifiable_id")
          .where.not("books_books.title ~ ?", ::Books::OpenLibrary::EvalExport::E2E_LEFTOVER_TITLE)
      end
    end
  end
end
