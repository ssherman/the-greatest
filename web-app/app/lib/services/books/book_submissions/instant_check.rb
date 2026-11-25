# frozen_string_literal: true

module Services
  module Books
    module BookSubmissions
      # Looks in our own Postgres for books a reader's submission may already be.
      # Runs inside the web request, so nothing outside the database is called:
      # no Open Library, search index, Redis-backed client or AI.
      #
      # `attributes` is ParseInput's data[:attributes]. A link or ISBN is matched
      # by identifier (work or edition level, every source but legacy; a row with
      # no source is skipped too); title and authors by exact normalized match,
      # and only when the authors leave a name to compare (ExactLookup would
      # otherwise answer by title alone).
      # Answers with up to MAX_BOOKS books, catalog before provisional, then
      # best primary rank (unranked last), then id.
      class InstantCheck
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        MAX_BOOKS = 3
        # Candidates read from the exact title lookup before ordering, so a
        # popular title cannot hide a ranked book behind the first few ids.
        TITLE_CANDIDATES = 50

        BOOK_TYPE = "Books::Book"
        EDITION_TYPE = "Books::Edition"
        GOODREADS_TYPES = %i[books_work_goodreads_id books_edition_goodreads_id].freeze
        ISBN13_TYPES = %i[books_work_isbn13 books_edition_isbn13].freeze
        ISBN10_TYPES = %i[books_work_isbn10 books_edition_isbn10].freeze
        ASIN_TYPES = %i[books_work_asin books_edition_asin].freeze

        def self.call(attributes:) = new(attributes).call

        def initialize(attributes)
          @attributes = attributes || {}
        end

        def call
          Result.new(success?: true, data: {books: ordered_books(candidate_ids)}, errors: [])
        end

        private

        def candidate_ids
          ids = identifier_book_ids
          ids |= title_book_ids
          ids
        end

        def identifier_book_ids
          lookups = identifier_lookups
          return [] if lookups.empty?

          scope = lookups.map { |types, values| Identifier.where(identifier_type: types, value: values) }.reduce(:or)
          rows = scope.where(identifiable_type: [BOOK_TYPE, EDITION_TYPE], source: Identifier::NON_LEGACY_SOURCES)
            .pluck(:identifiable_type, :identifiable_id)
          book_ids = rows.select { |type, _| type == BOOK_TYPE }.map(&:last)
          edition_ids = rows.select { |type, _| type == EDITION_TYPE }.map(&:last)
          book_ids | ::Books::Edition.where(id: edition_ids).pluck(:book_id)
        end

        # [identifier types, string values] per kind of id. identifiers.value is
        # a string column. The ISBN forms are completed from each other, and an
        # ASIN may be an ISBN-10, so it is also looked up as one.
        def identifier_lookups
          isbn = ::Books::Isbn.normalize(@attributes[:isbn13].presence || @attributes[:isbn10])
          isbn13 = [@attributes[:isbn13], isbn&.isbn13].compact_blank.uniq
          isbn10 = [@attributes[:isbn10], isbn&.isbn10].compact_blank.uniq
          asin = Array(@attributes[:asin].presence)
          goodreads = Array(@attributes[:goodreads_book_id]).compact

          [
            [GOODREADS_TYPES, goodreads],
            [ISBN13_TYPES, isbn13],
            [ISBN10_TYPES, isbn10 | asin.select { |value| value.match?(/\A\d{9}[\dX]\z/) }],
            [ASIN_TYPES, asin]
          ].reject { |_, values| values.empty? }
        end

        def title_book_ids
          names = Array(@attributes[:typed_author_names])
          return [] if @attributes[:typed_title].blank? || ::Services::Text::PersonNameKey.all(names).empty?

          DataImporters::Books::Book::ExactLookup.call(
            title: @attributes[:typed_title], author_names: names, limit: TITLE_CANDIDATES
          ).pluck(:id)
        end

        def ordered_books(ids)
          return [] if ids.empty?

          rank_join = ::Books::Book.sanitize_sql_array([<<~SQL.squish, ::Books::RankingConfiguration.default_primary&.id])
            LEFT JOIN ranked_items primary_ranks
              ON primary_ranks.item_type = 'Books::Book'
              AND primary_ranks.item_id = books_books.id
              AND primary_ranks.ranking_configuration_id = ?
          SQL
          ::Books::Book.where(id: ids).joins(rank_join).includes(:authors)
            .order(Arel.sql("books_books.provisional ASC, primary_ranks.rank ASC NULLS LAST, books_books.id ASC"))
            .limit(MAX_BOOKS).to_a
        end
      end
    end
  end
end
