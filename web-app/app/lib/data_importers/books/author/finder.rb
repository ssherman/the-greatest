# frozen_string_literal: true

module DataImporters
  module Books
    module Author
      # Finds an existing ::Books::Author before import and answers with a
      # Match (see FinderBase). Four sources, in order: the query's Open
      # Library author key, an exact normalized name-or-alternate-name
      # lookup, the OpenSearch AuthorByName query, and the Open Library
      # author record for the key.
      #
      # Rule 4 for authors is an equal normalized name (or alternate name)
      # with no birth- or death-year conflict. Two different people with the
      # same exact name and no dates on either side are therefore matched:
      # the accepted trade-off against a new author row on every re-import
      # (import-finder redesign §9).
      class Finder < DataImporters::FinderBase
        OPENSEARCH_SIZE = 5
        EXACT_LIMIT = 5
        EVIDENCE_BOOK_TITLES = 5

        # open_library_client: injected by tests; nil builds the real client
        # lazily inside OpenLibrarySource.
        def initialize(open_library_client: nil)
          @open_library_client = open_library_client
        end

        def exact_match?(query, candidate)
          super && !year_conflict?(query.death_year, candidate.record.death_year)
        end

        def describe_query(query)
          parts = [query.name.presence || query.open_library_author_key]
          span = life_span(query.birth_year, query.death_year)
          parts << span if span
          parts << "also known as #{query.alternate_names.join(", ")}" if query.alternate_names.any?
          parts << "wrote #{query.work_titles.first(EVIDENCE_BOOK_TITLES).join("; ")}" if query.work_titles.any?
          parts.join(" | ")
        end

        def describe_candidate(candidate)
          evidence = candidate.evidence
          parts = [evidence[:title].presence || evidence[:external_title].presence || candidate.external_key.to_s]
          span = life_span(evidence[:birth_year], evidence[:death_year])
          parts << span if span
          alternates = Array(evidence[:alternate_names]).first(5)
          parts << "also known as #{alternates.join(", ")}" if alternates.any?
          titles = Array(evidence[:book_titles])
          parts << "wrote #{titles.join("; ")}" if titles.any?
          parts << evidence[:kind].to_s if evidence[:kind].present? && evidence[:kind].to_s != "person"
          parts << "ranked ##{evidence[:ranked_position]}" if evidence[:ranked_position].present?
          parts << "in catalog" if candidate.local?
          parts << "#{candidate.external_source} #{candidate.external_key}" if candidate.external?
          parts << "shares #{evidence.dig(:matched_identifier, :type)}" if evidence[:matched_identifier]
          parts.join(" | ")
        end

        protected

        def model_class = ::Books::Author

        # An author's "title" is its name and alternate names.
        def title_key(text) = ::Services::Text::PersonNameKey.call(text)

        def ranking_configuration_class = ::Books::Authors::RankingConfiguration

        def candidate_sources(query)
          [
            DataImporters::Sources::Identifiers.new(model_class: ::Books::Author, lookups: identifier_lookups(query)),
            DataImporters::Sources::Exact.new(scope: exact_scope(query), limit: EXACT_LIMIT),
            DataImporters::Sources::OpenSearch.new(
              model_class: ::Books::Author,
              search_class: ::Search::Books::Search::AuthorByName,
              params: search_params(query),
              size: OPENSEARCH_SIZE,
              includes: [:identifiers]
            ),
            OpenLibrarySource.new(query: query, client: @open_library_client)
          ]
        end

        def domain_guidance
          "Two people with the same name are different authors unless their dates or their books connect them; a shared name alone is not enough. " \
            "A transliteration, a spelling variant, initials or a fuller form of the same person's name is the same author. " \
            "A pen name is a separate author from the person who used it."
        end

        def query_year(query) = query.birth_year

        def record_year(record) = record.birth_year

        def record_extra_evidence(record)
          {
            alternate_names: Array(record.alternate_names),
            birth_year: record.birth_year,
            death_year: record.death_year,
            kind: record.kind,
            book_titles: record.books.order(:id).limit(EVIDENCE_BOOK_TITLES).pluck(:title)
          }
        end

        private

        def identifier_lookups(query)
          return [] if query.open_library_author_key.blank?

          [[:books_author_openlibrary_id, query.open_library_author_key]]
        end

        # The query's name and alternate names against every stored name and
        # alternate name, compared as Services::Text::PersonNameKey keys
        # through the GIN-indexed books_authors.name_keys, so initials written
        # differently still meet. Ids are plucked first, as in the books
        # finder, so no ORDER BY + LIMIT steers the planner.
        def exact_scope(query)
          keys = ::Services::Text::PersonNameKey.all([query.name, *query.alternate_names])
          return ::Books::Author.none if keys.empty?

          ids = ::Books::Author.where("books_authors.name_keys && ARRAY[:keys]::varchar[]", keys: keys)
            .pluck(:id).sort.first(EXACT_LIMIT)
          ::Books::Author.where(id: ids).includes(:identifiers).order(:id)
        end

        def search_params(query)
          return nil if query.name.blank?

          {name: query.name, alternate_names: query.alternate_names}
        end

        def life_span(birth_year, death_year)
          return nil if birth_year.blank? && death_year.blank?

          "#{birth_year || "?"}-#{death_year}"
        end
      end
    end
  end
end
