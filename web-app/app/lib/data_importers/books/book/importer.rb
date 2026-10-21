# frozen_string_literal: true

module DataImporters
  module Books
    module Book
      # Main importer for single ::Books::Book records via the Open Library
      # resolve service.
      class Importer < DataImporters::ImporterBase
        def self.call(title: nil, subtitle: nil, author_names: [], year: nil, isbn13: [], isbn10: [], asin: [], goodreads_id: [],
          open_library_work_key: nil, item: nil, force_providers: false, providers: nil, subject: nil, verify: false,
          match: nil, provisional: false, stamp_identifiers: false, enrich: true, trust_work_key: false,
          query_identifier_source: :goodreads_import)
          importer = new(provisional: provisional, stamp_identifiers: stamp_identifiers, enrich: enrich,
            trust_work_key: trust_work_key, query_identifier_source: query_identifier_source)
          if item.present?
            importer.call(item: item, force_providers: force_providers, providers: providers)
          else
            query = ImportQuery.new(
              title: title,
              subtitle: subtitle,
              author_names: author_names,
              year: year,
              isbn13: isbn13,
              isbn10: isbn10,
              asin: asin,
              goodreads_id: goodreads_id,
              open_library_work_key: open_library_work_key
            )
            importer.call(query: query, force_providers: force_providers, providers: providers, subject: subject,
              verify: verify, match: match)
          end
        end

        # provisional: the book, and any author this import creates, are saved
        # provisional (Goodreads import spec §5, §9). stamp_identifiers: the
        # query's identifiers are stamped whatever Open Library says, so a
        # book made while the service is down can be found again by them.
        # enrich: false skips the Enrichment provider; an import's
        # enrichment is planned on admin approval instead. trust_work_key: the
        # query's Open Library work key wins over the service's decision (a
        # person confirmed it; the list wizard). query_identifier_source: the
        # source given to the query's own identifiers (the caller's claim,
        # not Open Library's). Only the Goodreads import passes identifiers
        # today.
        def initialize(provisional: false, stamp_identifiers: false, enrich: true, trust_work_key: false,
          query_identifier_source: :goodreads_import)
          @provisional = provisional
          @stamp_identifiers = stamp_identifiers
          @enrich = enrich
          @trust_work_key = trust_work_key
          @query_identifier_source = query_identifier_source
        end

        def call(**)
          result = super
          result.created_author_ids = new_author_ids.dup
          result
        end

        protected

        def finder
          @finder ||= Finder.new
        end

        # OpenLibrary first: its fills are free and licensed, and on accept it
        # links the work's authors. Authors next: the query's author names
        # when the book still has none (an abstain, a reject, or the service
        # unreachable). QueryIdentifiers runs after Authors when
        # stamp_identifiers is asked for. Enrichment is last, when enrich is
        # on: it plans an author run for each author this import created and
        # one book run (Workflows::Books::BookEnrichment): its AI step waits
        # for those authors' chains, and its Amazon step runs independently.
        # It needs the book's book_authors saved, which the importer does
        # after each successful provider. enrich: false plans nothing.
        def providers
          @providers ||= begin
            list = [
              Providers::OpenLibrary.new(new_author_ids: new_author_ids, provisional: @provisional, trust_work_key: @trust_work_key,
                query_identifier_source: @query_identifier_source),
              Providers::Authors.new(new_author_ids: new_author_ids, provisional: @provisional)
            ]
            list << Providers::QueryIdentifiers.new(source: @query_identifier_source) if @stamp_identifiers
            if @enrich
              list << Providers::Enrichment.new(new_author_ids: new_author_ids)
            end
            list
          end
        end

        # The authors this import created: the author steps add to it, and
        # the providers after them read it.
        def new_author_ids
          @new_author_ids ||= []
        end

        # Seeds first_published_year alongside title, not title alone -- the
        # OpenLibrary provider builds its /resolve request from the BOOK
        # (R106), so a title-only seed would make the query's year look like
        # the book's own value, the service would call it agreement instead
        # of a fill, and the year would never actually get written.
        def initialize_item(query)
          ::Books::Book.new(
            title: query.title,
            subtitle: query.subtitle,
            first_published_year: query.year,
            provisional: @provisional
          )
        end
      end
    end
  end
end
