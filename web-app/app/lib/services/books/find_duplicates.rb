# frozen_string_literal: true

module Services
  module Books
    # The duplicate sweep for one book (spec §16): resolve it against the
    # rest of the catalog by calling the finder with the book's own fields,
    # verify on (no identifier early exit) and the book itself excluded. A
    # match means another local book is the same work; the pair is raised
    # as bulk_verify. Nothing else is written and no provider runs.
    #
    # Callable from a console for one book:
    #   Services::Books::FindDuplicates.call(book: Books::Book.find_by(slug: "dune"))
    # `data[:match]` is the finder's Match (candidates, reason, decision);
    # `data[:pair]` is the DuplicateCandidate row, or nil when unmatched.
    #
    # Re-running is safe for pairs (a pending pair gains an occurrence, a
    # dismissed one is never re-raised); it does write a fresh
    # match_decisions row per call. Books::FindDuplicatesJob drives this
    # one book at a time on the serial queue.
    class FindDuplicates
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      QUERY_IDENTIFIERS = {
        isbn13: "books_work_isbn13",
        isbn10: "books_work_isbn10",
        asin: "books_work_asin",
        goodreads_id: "books_work_goodreads_id",
        open_library_work_key: "books_work_openlibrary_id"
      }.freeze

      # A ranked book can carry dozens of identifiers per type (the #1 book
      # has 107). The sweep wants OTHER local books, and a few values per
      # type give the identifier source its collision evidence without 100
      # lookups per book or a /resolve body the service was never timed
      # against.
      IDENTIFIERS_PER_TYPE = 3

      def self.call(book:, finder: nil)
        new(book: book, finder: finder).call
      end

      def initialize(book:, finder: nil)
        @book = book
        @finder = finder || DataImporters::Books::Book::Finder.new
      end

      # Fails, without flagging, when the finder's Open Library source
      # failed: that source is what finds a translation held under another
      # title (spec §16), so a decision made without it is not the sweep's
      # answer. The match is still returned in data for inspection.
      def call
        match = @finder.call(query: query, verify: true, subject: @book, exclude: @book)

        if match.sources_failed.include?("open_library")
          return Result.new(success?: false, data: {match: match, pair: nil},
            errors: ["Open Library source failed for Books::Book##{@book.id}: #{match.reason}"])
        end

        pair = flag_pair(match) if match.matched?
        Result.new(success?: true, data: {match: match, pair: pair}, errors: [])
      end

      private

      def query
        by_type = @book.identifiers.group_by(&:identifier_type)
        # Sorted so the capped subset is the same on every run of the sweep.
        values = ->(type) { Array(by_type[type]).map(&:value).sort }

        DataImporters::Books::Book::ImportQuery.new(
          title: @book.title,
          author_names: @book.authors.map(&:name),
          year: @book.first_published_year,
          isbn13: values.call(QUERY_IDENTIFIERS[:isbn13]).first(IDENTIFIERS_PER_TYPE),
          isbn10: values.call(QUERY_IDENTIFIERS[:isbn10]).first(IDENTIFIERS_PER_TYPE),
          asin: values.call(QUERY_IDENTIFIERS[:asin]).first(IDENTIFIERS_PER_TYPE),
          goodreads_id: values.call(QUERY_IDENTIFIERS[:goodreads_id]).first(IDENTIFIERS_PER_TYPE),
          open_library_work_key: values.call(QUERY_IDENTIFIERS[:open_library_work_key]).first
        )
      end

      def flag_pair(match)
        ::Services::DuplicateCandidates::Flag.call(
          item_type: "Books::Book",
          ids: [@book.id, match.record.id],
          source: :bulk_verify,
          evidence: {reason: match.reason, decided_by: match.decided_by.to_s, confidence: match.confidence.to_s},
          match_decision: match.decision
        ).data
      end
    end
  end
end
