# frozen_string_literal: true

module Services
  module Books
    module GoodreadsImports
      # The books finder query for a Goodreads edition (Goodreads import spec §5):
      # its title and primary author, year, ISBNs and Goodreads id, with the
      # series and the other credited names as AI context. Shared by member
      # resolution and the legacy replay, so both ask the same question.
      class EditionQuery
        def self.call(edition)
          ::DataImporters::Books::Book::ImportQuery.new(
            title: edition.title,
            author_names: [edition.primary_author],
            year: edition.original_publication_year || edition.year_published,
            isbn13: [edition.isbn13],
            isbn10: [edition.isbn10],
            goodreads_id: [edition.goodreads_book_id.to_s],
            series_name: edition.series_name,
            series_number: edition.series_number,
            context_author_names: edition.additional_authors
          )
        end
      end
    end
  end
end
