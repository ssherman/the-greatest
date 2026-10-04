# frozen_string_literal: true

module DataImporters
  module Books
    module Author
      # Main importer for single ::Books::Author records. The book importer's
      # author step is the first caller.
      class Importer < DataImporters::ImporterBase
        # The providers a book import runs for an author it creates: all but
        # the async Enrichment, which the book importer starts itself once
        # the book and its book_authors rows are saved, so the Wikidata step
        # sees the book among the author's titles (spec §10).
        BOOK_STEP_PROVIDERS = %i[open_library].freeze

        def self.call(name: nil, open_library_author_key: nil, birth_year: nil, death_year: nil, alternate_names: [], work_titles: [],
          item: nil, force_providers: false, providers: nil, subject: nil, verify: false, provisional: false)
          importer = new(provisional: provisional)
          if item.present?
            importer.call(item: item, force_providers: force_providers, providers: providers)
          else
            query = ImportQuery.new(
              name: name,
              open_library_author_key: open_library_author_key,
              birth_year: birth_year,
              death_year: death_year,
              alternate_names: alternate_names,
              work_titles: work_titles
            )
            importer.call(query: query, force_providers: force_providers, providers: providers, subject: subject, verify: verify)
          end
        end

        # provisional: an author this import creates is saved provisional; an
        # author it matches is returned untouched (Goodreads import spec §9).
        def initialize(provisional: false)
          @provisional = provisional
        end

        protected

        def finder
          @finder ||= Finder.new
        end

        def providers
          @providers ||= [Providers::OpenLibrary.new, Providers::Enrichment.new]
        end

        # A name alone is a complete author: keep it even when Open Library is
        # unreachable (the service is not deployed to production), so the book
        # importer's author step always gets a record to link.
        def save_before_providers? = true

        def initialize_item(query)
          ::Books::Author.new(
            name: query.name,
            birth_year: query.birth_year,
            death_year: query.death_year,
            alternate_names: query.alternate_names.reject { |alternate| alternate == query.name },
            provisional: @provisional
          )
        end
      end
    end
  end
end
