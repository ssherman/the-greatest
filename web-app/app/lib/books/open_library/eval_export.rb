# frozen_string_literal: true

module Books
  module OpenLibrary
    # Streams every Books::Book as JSONL for the Open Library evaluation-set
    # pool builder. Read-only: this class must never write to the database.
    class EvalExport
      # Every admin E2E spec titles its fixture with a trailing `${Date.now()}`
      # -- "E2E Smoke Book 1784091457158", "Tag Book 1785655579265" -- and
      # nothing cleans them up, so 126 of them sit in the development database
      # and would be exported as if they were books. They are not: none carries
      # a single identifier, and they are eligible for every stratum in the
      # evaluation pool. The draw before this filter spent 20 of 450
      # hand-labelling slots on them, 19 in `author_less_work` alone.
      #
      # Keyed on the epoch-millisecond stamp rather than the per-spec prefixes,
      # because the stamp is what every spec has in common and a new spec with
      # a new prefix would escape a prefix list. Measured against the
      # development database: this matches 126 rows, exactly the same 126 the
      # prefix list matches, and no genuine book.
      E2E_LEFTOVER_TITLE = "[[:space:]][0-9]{13}$"

      IDENTIFIER_FIELDS = {
        books_work_isbn13: "isbn13",
        books_work_isbn10: "isbn10",
        books_work_asin: "asin",
        books_work_goodreads_id: "goodreads_id",
        books_work_openlibrary_id: "existing_ol_work_keys"
      }.freeze

      def self.call(io:, batch_size: 1000)
        new(io: io, batch_size: batch_size).call
      end

      def initialize(io:, batch_size: 1000)
        @io = io
        @batch_size = batch_size
      end

      def call
        count = 0

        scope.find_each(batch_size: @batch_size) do |book|
          @io.puts(JSON.generate(record_for(book)))
          count += 1
        end

        count
      end

      private

      # No `.order` here: `find_each` batches by primary key and discards any
      # scope order it is handed, warning each time it does. Ascending id is
      # what the export wants and what batching already gives it.
      def scope
        ::Books::Book
          .where.not("title ~ ?", E2E_LEFTOVER_TITLE)
          .includes(:identifiers, :original_language, book_authors: {author: :identifiers})
      end

      def record_for(book)
        grouped = Hash.new { |hash, key| hash[key] = [] }
        book.identifiers.each do |identifier|
          field = IDENTIFIER_FIELDS[identifier.identifier_type.to_sym]
          grouped[field] << identifier.value if field
        end

        authors = book.book_authors.map(&:author)

        {
          book_id: book.id,
          title: book.title,
          subtitle: book.subtitle,
          sort_title: book.sort_title,
          alternate_titles: book.alternate_titles,
          first_published_year: book.first_published_year,
          book_kind: book.book_kind,
          original_language_slug: book.original_language&.slug,
          author_names: authors.map(&:name),
          existing_ol_author_keys: authors.flat_map { |author|
            author.identifiers
              .select { |identifier| identifier.identifier_type == "books_author_openlibrary_id" }
              .map(&:value)
          },
          existing_ol_work_keys: grouped["existing_ol_work_keys"],
          isbn13: grouped["isbn13"],
          isbn10: grouped["isbn10"],
          asin: grouped["asin"],
          goodreads_id: grouped["goodreads_id"]
        }
      end
    end
  end
end
