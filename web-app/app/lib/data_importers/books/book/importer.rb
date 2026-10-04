# frozen_string_literal: true

module DataImporters
  module Books
    module Book
      # Main importer for single ::Books::Book records via the Open Library
      # resolve service.
      class Importer < DataImporters::ImporterBase
        def self.call(title: nil, author_names: [], year: nil, isbn13: [], isbn10: [], asin: [], goodreads_id: [],
          open_library_work_key: nil, item: nil, force_providers: false, providers: nil, subject: nil, verify: false,
          match: nil, provisional: false, stamp_identifiers: false, enrich: true)
          importer = new(provisional: provisional, stamp_identifiers: stamp_identifiers, enrich: enrich)
          if item.present?
            importer.call(item: item, force_providers: force_providers, providers: providers)
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
            importer.call(query: query, force_providers: force_providers, providers: providers, subject: subject,
              verify: verify, match: match)
          end
        end

        # provisional: the book, and any author this import creates, are saved
        # provisional (Goodreads import spec §5, §9). stamp_identifiers: the
        # query's identifiers are stamped whatever Open Library says, so a
        # book made while the service is down can be found again by them.
        # enrich: false skips AiEnrichment and AuthorEnrichment; an import's
        # enrichment runs on admin approval instead.
        def initialize(provisional: false, stamp_identifiers: false, enrich: true)
          @provisional = provisional
          @stamp_identifiers = stamp_identifiers
          @enrich = enrich
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
        # unreachable). AiEnrichment then runs, so the AI fills fewer blanks;
        # it defers the book to its new authors' chain when one is linked.
        # AuthorEnrichment runs last, after the deferral row is written, so it
        # starts that chain for the authors this import created -- both it
        # and AiEnrichment run after the save that follows Authors, so the
        # chain sees this book among their titles (spec §10). QueryIdentifiers
        # runs after Authors when stamp_identifiers is asked for; enrich: false
        # drops the two enrichment providers.
        def providers
          @providers ||= begin
            list = [
              Providers::OpenLibrary.new(new_author_ids: new_author_ids, provisional: @provisional),
              Providers::Authors.new(new_author_ids: new_author_ids, provisional: @provisional)
            ]
            list << Providers::QueryIdentifiers.new if @stamp_identifiers
            if @enrich
              list << Providers::AiEnrichment.new(new_author_ids: new_author_ids)
              list << Providers::AuthorEnrichment.new(new_author_ids: new_author_ids)
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
            first_published_year: query.year,
            provisional: @provisional
          )
        end
      end
    end
  end
end
