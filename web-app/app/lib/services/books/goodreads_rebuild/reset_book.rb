# frozen_string_literal: true

module Services
  module Books
    module GoodreadsRebuild
      # Wipes a derived book's legacy-guessed metadata in place (rebuild fixes
      # increment, Task 3). The legacy Goodreads import built these books from
      # a wrong title and author, so everything hung on them is a guess too.
      # The record itself stays, with its id, slug and everything users hang on
      # it (list items, reviews, goodreads editions...), so the caller can set
      # the export title and re-import authors and identifiers afterwards.
      #
      # Nothing here is lost for good: the identifiers, the editions' identifiers
      # and the links (Amazon ASINs and product links among them) come back in
      # data[:removed], which the caller stores on the repair verdict.
      #
      # Trusted books are refused: their data is not legacy's guess.
      class ResetBook
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        ASSOCIATIONS = %i[book_authors credits descriptions category_items images editions identifiers
          alternate_title_records series_books book_countries external_links].freeze

        COLUMNS = {
          description: nil, subtitle: nil, sort_title: nil, first_published_year: nil, original_language_id: nil,
          default_edition_id: nil, book_length: nil, page_range: nil, word_count: nil, amazon_enriched_at: nil,
          alternate_titles: []
        }.freeze

        def self.call(book:)
          new(book: book).call
        end

        def initialize(book:)
          @book = book
        end

        def call
          raise ArgumentError, "book #{@book.id} is trusted; it is never reset" if Cohort.trusted?(@book.id)

          removed = archive
          ::Books::Book.transaction do
            # The default edition's foreign key would block destroying editions.
            @book.update_columns(default_edition_id: nil)
            ASSOCIATIONS.each { |name| @book.public_send(name).reload.destroy_all }
            @book.update_columns(COLUMNS.merge(updated_at: Time.current))
          end
          @book.reload
          SearchIndexRequest.create!(parent: @book, action: :index_item)
          Result.new(success?: true, data: {book: @book, removed: removed}, errors: [])
        end

        private

        # Built before anything is deleted; string keys so it survives a JSON round trip.
        def archive
          {
            "title" => @book.title,
            "subtitle" => @book.subtitle,
            "author_names" => @book.authors.reload.map(&:name),
            "identifiers" => @book.identifiers.map { |i| [i.identifier_type, i.value, i.source] },
            "external_links" => links(@book.external_links),
            "editions" => @book.editions.includes(:identifiers, :external_links).map do |edition|
              {
                "title" => edition.title,
                "identifiers" => edition.identifiers.map { |i| [i.identifier_type, i.value] },
                "external_links" => links(edition.external_links)
              }
            end
          }
        end

        def links(scope) = scope.map { |link| [link.url, link.source] }
      end
    end
  end
end
