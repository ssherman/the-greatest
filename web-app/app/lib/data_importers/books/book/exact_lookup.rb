# frozen_string_literal: true

module DataImporters
  module Books
    module Book
      # Normalized title equality (served by the lower(title) expression
      # index), joined to an author whose name keys
      # (Services::Text::PersonNameKey, GIN-indexed books_authors.name_keys)
      # meet the query's when the query names authors. A title-only query still yields
      # title matches: they are candidates for the AI, never a rule-4
      # match, because creators_required? is true for books.
      #
      # The filtered ids are plucked first, with no ORDER BY or LIMIT on
      # the filtered query: measured on 158k books, ORDER BY id + LIMIT 5
      # on the filtered relation makes the planner walk the primary key
      # (59 ms, every row filtered) instead of using
      # index_books_books_on_lower_title (0.01 ms). A title matches a
      # handful of rows, so plucking them all is cheap.
      #
      # Shared by the finder's exact source and the book-submission instant
      # check, which must not leave Postgres.
      class ExactLookup
        def self.call(title:, author_names:, limit: 5) = new(title, author_names, limit).call

        def initialize(title, author_names, limit)
          @title = title
          @author_names = author_names
          @limit = limit
        end

        def call
          return ::Books::Book.none if @title.blank?

          filtered = ::Books::Book.where("LOWER(books_books.title) = ?", normalize(@title))
          keys = ::Services::Text::PersonNameKey.all(@author_names)
          if keys.any?
            filtered = filtered.joins(book_authors: :author)
              .where("books_authors.name_keys && ARRAY[:keys]::varchar[]", keys: keys)
          end
          ids = filtered.distinct.pluck(:id).sort.first(@limit)
          ::Books::Book.where(id: ids).includes(:authors, :identifiers).order(:id)
        end

        private

        def normalize(text)
          ::Services::Text::NameNormalizer.call(::Services::Text::QuoteNormalizer.call(text.to_s)).downcase
        end
      end
    end
  end
end
