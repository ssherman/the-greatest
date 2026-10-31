# frozen_string_literal: true

module DataImporters
  module Books
    module Book
      # Finds an existing ::Books::Book before import and answers with a
      # Match (see FinderBase). Four sources, in order: identifiers (Open
      # Library work key, ISBN-13, ISBN-10, ASIN, Goodreads id), an exact
      # normalized title-plus-author lookup, the OpenSearch title-plus-
      # authors query, and the Open Library resolve service (or, by mode, its
      # identifier lookup, both, or neither).
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
        # Which Open Library sources run: :resolve (the /resolve service, the
        # default), :identifiers (the fast identifier lookup only; the Goodreads
        # replay's pass one), :all (both; its pass two) or :none (no Open Library
        # source at all).
        OPEN_LIBRARY_MODES = %i[resolve identifiers all none].freeze
        # Identifier sources a "blinded" lookup trusts. Legacy's Goodreads import
        # stamped wrong ISBNs and Goodreads ids onto books, so rows from any
        # other source are ignored when this is passed as identifier_sources.
        TRUSTED_IDENTIFIER_SOURCES = (Identifier::VERIFIED_SOURCES + ["goodreads_import"]).freeze
        # Alternate-title sources a "blinded" lookup trusts. Legacy stored wrong
        # alternate titles on derived books (a "Concise" edition holding the full
        # title), so a legacy row is never evidence. A merge row is not either: the
        # merger copies the absorbed book's own title across, which for a derived
        # book is legacy's guess. An AI enrichment, an admin or a correction wrote
        # the rest.
        TRUSTED_ALTERNATE_TITLE_SOURCES = (AlternateTitle.sources.keys - %w[legacy merge]).freeze

        # open_library_client: injected by tests; nil builds the real client
        # lazily inside the Open Library sources. identifier_sources: restricts
        # the identifier lookup to rows from these Identifier sources; nil
        # trusts every row. alternate_title_sources: does the same for alternate
        # titles: given, only kept AlternateTitle rows from these sources count,
        # for the title rules and for what the AI is shown; nil keeps the
        # books_books.alternate_titles array as it is.
        def initialize(open_library_client: nil, open_library: :resolve, identifier_sources: nil, alternate_title_sources: nil)
          raise ArgumentError, "unknown open_library mode: #{open_library.inspect}" unless OPEN_LIBRARY_MODES.include?(open_library)

          @open_library_client = open_library_client
          @open_library = open_library
          @identifier_sources = identifier_sources
          @alternate_title_sources = alternate_title_sources
        end

        def describe_candidate(candidate)
          line = super
          line = "#{line} | collection" if candidate.evidence[:book_kind].to_s == "collection"
          line
        end

        def describe_query(query)
          line = super
          if query.series_name.present?
            line = "#{line} | series: #{[query.series_name, query.series_number && "##{query.series_number}"].compact.join(" ")}"
          end
          line = "#{line} | also credited, role unknown: #{query.context_author_names.join(", ")}" if query.context_author_names.any?
          line
        end

        # The stored Open Library work keys were assigned by old matching code,
        # and some point at another book by the same author (a novel holding
        # its sequel's key). An agreeing author alone would settle that wrong
        # book as certain, so the title has to agree; otherwise the holder is
        # left to the exact rule and the AI.
        def external_accept_corroborated?(query, candidate)
          return true if query_title(query).blank? && query_creators(query).empty?

          titles_agree?(query, candidate.record)
        end

        protected

        def model_class = ::Books::Book

        def ranking_configuration_class = ::Books::RankingConfiguration

        def creators_required? = true

        def candidate_sources(query)
          [
            DataImporters::Sources::Identifiers.new(model_class: ::Books::Book, lookups: identifier_lookups(query),
              sources: @identifier_sources),
            DataImporters::Sources::Exact.new(scope: exact_scope(query), limit: EXACT_LIMIT),
            DataImporters::Sources::OpenSearch.new(
              model_class: ::Books::Book,
              search_class: ::Search::Books::Search::BookByTitleAndAuthors,
              params: search_params(query),
              size: OPENSEARCH_SIZE,
              includes: [:authors, :identifiers]
            )
          ] + open_library_sources(query)
        end

        def domain_guidance
          "A translation, a retitled edition or an alternate spelling of the same work is the same book. " \
            "A collection or omnibus is not the same as one of the works inside it, and one volume of a series is not the series. " \
            "An adaptation (a graphic novel, manga, pop-up book, play or screenplay, retelling), a study guide, a summary or a commentary is a different book from the work it is based on. " \
            "Two books with the same title by different authors are different books."
        end

        # An adaptation or a guide is a different book from its source, whatever
        # the title match, search score or AI says (DerivativeWork). Applies to
        # external works too, so a member import does not create the original
        # from an Open Library adaptation record.
        def incompatible?(query, candidate)
          # A Goodreads id names one edition, so a book holding it is that edition
          # whatever its title says; dropping it would make a member's import
          # create a duplicate every time.
          return false if candidate.evidence.dig(:matched_identifier, :type).to_s == "books_work_goodreads_id"

          # An identifier-only query has nothing to compare, so it must reach its holder.
          return false if query.title.blank? && query.subtitle.blank?

          theirs = if candidate.local?
            [candidate.record.title, candidate.record.subtitle]
          else
            [candidate.evidence[:title], candidate.evidence[:subtitle]]
          end
          DerivativeWork.differ?([query.title, query.subtitle].compact_blank.join(": "), theirs.compact_blank.join(": "))
        end

        def query_creators(query) = query.author_names

        def record_creators(record) = record.authors.map(&:name)

        def record_creator_alternate_names(record) = record.authors.flat_map { |author| Array(author.alternate_names) }

        # Authors are people: initials written differently are one name.
        def creator_key(text) = ::Services::Text::PersonNameKey.call(text)

        def record_year(record) = record.first_published_year

        def record_extra_evidence(record)
          {book_kind: record.book_kind, alternate_titles: record_alternate_titles(record)}
        end

        def record_alternate_titles(record)
          return Array(record.alternate_titles) unless @alternate_title_sources

          record.alternate_title_records
            .select { |row| row.status == "kept" && @alternate_title_sources.include?(row.source) }
            .map(&:title)
        end

        private

        def open_library_sources(query)
          return [] if @open_library == :none

          sources = []
          sources << OpenLibraryIdentifierSource.new(query: query, client: @open_library_client) unless @open_library == :resolve
          sources << OpenLibrarySource.new(query: query, client: @open_library_client, limit: OPEN_LIBRARY_LIMIT) unless @open_library == :identifiers
          sources
        end

        def identifier_lookups(query)
          IDENTIFIER_LOOKUPS.flat_map do |field, identifier_type|
            Array(query.public_send(field)).map { |value| [identifier_type, value] }
          end
        end

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
        def exact_scope(query)
          return ::Books::Book.none if query.title.blank?

          filtered = ::Books::Book.where("LOWER(books_books.title) = ?", normalize(query.title))
          keys = ::Services::Text::PersonNameKey.all(query.author_names)
          if keys.any?
            filtered = filtered.joins(book_authors: :author)
              .where("books_authors.name_keys && ARRAY[:keys]::varchar[]", keys: keys)
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
