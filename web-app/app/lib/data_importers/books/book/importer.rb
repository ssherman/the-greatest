# frozen_string_literal: true

module DataImporters
  module Books
    module Book
      # Main importer for single ::Books::Book records via the Open Library
      # resolve service.
      class Importer < DataImporters::ImporterBase
        def self.call(title: nil, author_names: [], year: nil, isbn13: [], isbn10: [], asin: [], goodreads_id: [],
          open_library_work_key: nil, item: nil, force_providers: false, providers: nil, subject: nil, verify: false)
          if item.present?
            super(item: item, force_providers: force_providers, providers: providers)
          else
            query = ImportQuery.new(
              title: title,
              author_names: author_names,
              year: year,
              isbn13: isbn13,
              isbn10: isbn10,
              asin: asin,
              goodreads_id: goodreads_id,
              open_library_work_key: open_library_work_key
            )
            super(query: query, force_providers: force_providers, providers: providers, subject: subject, verify: verify)
          end
        end

        protected

        def finder
          @finder ||= Finder.new
        end

        # OpenLibrary first: its fills are free and licensed, so the AI run
        # that follows has fewer blanks to fill.
        def providers
          @providers ||= [Providers::OpenLibrary.new, Providers::AiEnrichment.new]
        end

        # Seeds first_published_year alongside title, not title alone -- the
        # OpenLibrary provider builds its /resolve request from the BOOK
        # (R106), so a title-only seed would make the query's year look like
        # the book's own value, the service would call it agreement instead
        # of a fill, and the year would never actually get written.
        def initialize_item(query)
          ::Books::Book.new(
            title: query.title,
            first_published_year: query.year
          )
        end
      end
    end
  end
end
