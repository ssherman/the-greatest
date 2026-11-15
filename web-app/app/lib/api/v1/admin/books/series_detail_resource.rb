# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # One series with its representative book and every book in it, ordered
        # position NULLS LAST then link id. `position` is decimal(8,2); it is
        # emitted as a Float so it is a JSON number, not a BigDecimal string.
        # Key order is the order of AdminSeriesDetail in
        # config/api/v1/admin_openapi.yaml. Root-anchor every ::Books:: reference.
        class SeriesDetailResource < SeriesResource
          attribute :representative_book do |series|
            book = series.representative_book
            book && {id: book.id, title: book.title}
          end

          attribute :books do |series|
            rows = series.series_books.reorder(Arel.sql("books_series_books.position ASC NULLS LAST, books_series_books.id ASC"))
              .includes(book: {book_authors: :author})
            rows.map do |row|
              book = row.book
              authors = book.book_authors.sort_by { |link| [link.position || Float::INFINITY, link.id] }
                .map { |link| {id: link.author.id, name: link.author.name} }
              {
                id: book.id, title: book.title, slug: book.slug, first_published_year: book.first_published_year,
                authors: authors, position: row.position&.to_f, numbered: row.numbered, position_label: row.position_label
              }
            end
          end
        end
      end
    end
  end
end
