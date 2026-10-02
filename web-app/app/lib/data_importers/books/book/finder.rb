# frozen_string_literal: true

module DataImporters
  module Books
    module Book
      # Finds an existing ::Books::Book before import and answers with a
      # Match (see FinderBase). Four sources, in order: identifiers (Open
      # Library work key, ISBN-13, ISBN-10, ASIN, Goodreads id), an exact
      # normalized title-plus-author lookup, the OpenSearch title-plus-
      # authors query, and the Open Library resolve service.
      class Finder < DataImporters::FinderBase
        IDENTIFIER_LOOKUPS = [
          [:open_library_work_key, :books_work_openlibrary_id],
          [:isbn13, :books_work_isbn13],
          [:isbn10, :books_work_isbn10],
          [:asin, :books_work_asin],
          [:goodreads_id, :books_work_goodreads_id]
        ].freeze
        OPENSEARCH_SIZE = 5
        OPEN_LIBRARY_LIMIT = 5
        EXACT_LIMIT = 5

        # open_library_client: injected by tests; nil builds the real client
        # lazily inside OpenLibrarySource.
        def initialize(open_library_client: nil)
          @open_library_client = open_library_client
        end

        def describe_candidate(candidate)
          line = super
          line = "#{line} | collection" if candidate.evidence[:book_kind].to_s == "collection"
          line
        end

        protected

        def model_class = ::Books::Book

        def ranking_configuration_class = ::Books::RankingConfiguration

        def creators_required? = true

        def candidate_sources(query)
          [
            DataImporters::Sources::Identifiers.new(model_class: ::Books::Book, lookups: identifier_lookups(query)),
            DataImporters::Sources::Exact.new(scope: exact_scope(query), limit: EXACT_LIMIT),
            DataImporters::Sources::OpenSearch.new(
              model_class: ::Books::Book,
              search_class: ::Search::Books::Search::BookByTitleAndAuthors,
              params: search_params(query),
              size: OPENSEARCH_SIZE,
              includes: [:authors, :identifiers]
            ),
            OpenLibrarySource.new(query: query, client: @open_library_client, limit: OPEN_LIBRARY_LIMIT)
          ]
        end

        def domain_guidance
          "A translation, a retitled edition or an alternate spelling of the same work is the same book. " \
            "A collection or omnibus is not the same as one of the works inside it, and one volume of a series is not the series. " \
            "Two books with the same title by different authors are different books."
        end

        def query_creators(query) = query.author_names

        def record_creators(record) = record.authors.map(&:name)

        def record_creator_alternate_names(record) = record.authors.flat_map { |author| Array(author.alternate_names) }

        def record_year(record) = record.first_published_year

        def record_extra_evidence(record)
          {book_kind: record.book_kind, alternate_titles: Array(record.alternate_titles)}
        end

        private

        def identifier_lookups(query)
          IDENTIFIER_LOOKUPS.flat_map do |field, identifier_type|
            Array(query.public_send(field)).map { |value| [identifier_type, value] }
          end
        end

        # Normalized title equality (served by the lower(title) expression
        # index), joined to an author whose name or alternate name matches
        # when the query names authors. A title-only query still yields
        # title matches: they are candidates for the AI, never a rule-4
        # match, because creators_required? is true for books.
        #
        # The filtered ids are plucked first, with no ORDER BY or LIMIT on
        # the filtered query: measured on 158k books, ORDER BY id + LIMIT 5
        # on the filtered relation makes the planner walk the primary key
        # (59 ms, every row filtered) instead of using
        # index_books_books_on_lower_title (0.01 ms). A title matches a
        # handful of rows, so plucking them all is cheap.
        def exact_scope(query)
          return ::Books::Book.none if query.title.blank?

          filtered = ::Books::Book.where("LOWER(books_books.title) = ?", normalize(query.title))
          names = query.author_names.map { |name| normalize(name) }.compact_blank
          if names.any?
            filtered = filtered.joins(book_authors: :author).where(
              "LOWER(books_authors.name) IN (:names) OR EXISTS (SELECT 1 FROM unnest(books_authors.alternate_names) AS alternate WHERE LOWER(alternate) IN (:names))",
              names: names
            )
          end
          ids = filtered.distinct.pluck(:id).sort.first(EXACT_LIMIT)
          ::Books::Book.where(id: ids).includes(:authors, :identifiers).order(:id)
        end

        def search_params(query)
          return nil if query.title.blank?

          {title: query.title, authors: query.author_names, year: query.year}
        end
      end
    end
  end
end
