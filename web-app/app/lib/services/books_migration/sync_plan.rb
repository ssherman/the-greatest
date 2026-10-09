module Services
  module BooksMigration
    # One sync run's plan (spec §5, §7), built once at the start. data_migration:sync
    # applies its scope and data_migration:sync_report only prints it, so the two
    # cannot drift. Building it writes nothing.
    class SyncPlan
      DELAY = 24.hours
      TABLES = {"books" => "books_books", "authors" => "books_authors"}.freeze

      Window = Struct.new(:ids, :waiting, keyword_init: true)

      attr_reader :watermarks, :scope, :next_watermarks, :report

      def self.build(final: false, now: Time.current, legacy: LegacySource.new)
        new(final: final, now: now, legacy: legacy)
      end

      def initialize(final:, now:, legacy:)
        @legacy = legacy
        @cutoff = final ? nil : now - DELAY
        @initialized_at = LegacySyncWatermark.minimum(:created_at)
        @watermarks = initialized? ? stored_watermarks : provisional_watermarks
        redirects = Redirects.load

        books = window(legacy.book_rows_above(@watermarks["books"]))
        authors = window(legacy.author_rows_above(@watermarks["authors"]))
        identifiers = if @watermarks["book_identifiers"]
          window(legacy.book_identifier_rows_above(@watermarks["book_identifiers"]))
        else
          Window.new(ids: [], waiting: 0)
        end

        @scope = SyncScope.new(
          book_ids: books.ids.to_set - redirects.redirected_ids("Books::Book"),
          author_ids: authors.ids.to_set - redirects.redirected_ids("Books::Author"),
          identifier_ids: identifiers.ids.to_set,
          redirects: redirects
        )
        @next_watermarks = {
          "books" => books.ids.max || @watermarks["books"],
          "authors" => authors.ids.max || @watermarks["authors"],
          "book_identifiers" => identifiers.ids.max || @watermarks["book_identifiers"]
        }
        @report = build_report(books, authors, identifiers, redirects)
      end

      def initialized?
        !@initialized_at.nil?
      end

      private

      def stored_watermarks
        stored = LegacySyncWatermark.pluck(:key, :value).to_h
        missing = LegacySyncWatermark::KEYS - stored.keys
        raise "legacy_sync_watermarks is missing #{missing.join(", ")}; restore the rows before syncing" if missing.any?

        stored
      end

      # Before sync_init (sync_report only): the last legacy-origin ids here stand
      # in for the books and authors watermarks. There is no identifier watermark yet.
      def provisional_watermarks
        {
          "books" => Services::BooksMigration.max_legacy_origin_id("books_books"),
          "authors" => Services::BooksMigration.max_legacy_origin_id("books_authors"),
          "book_identifiers" => nil
        }
      end

      # Rows above a watermark, in id order. Legacy ids grow with created_at, so
      # the rows old enough to copy are a prefix. Everything from the first row
      # still inside the delay waits, even an older row behind it, so a watermark
      # never passes a row that has not been copied.
      def window(rows)
        first_waiting = @cutoff && rows.index { |_id, created_at| created_at > @cutoff }
        eligible = first_waiting ? rows.first(first_waiting) : rows
        Window.new(ids: eligible.map(&:first), waiting: rows.size - eligible.size)
      end

      def build_report(books, authors, identifiers, redirects)
        {
          initialized: initialized?,
          watermarks: @watermarks,
          books: record_counts("books", ::Books::Book, books, @scope.book_ids, @legacy.book_ids),
          authors: record_counts("authors", ::Books::Author, authors, @scope.author_ids, @legacy.author_ids),
          book_identifiers: {
            would_insert: (@watermarks["book_identifiers"] ? identifiers.ids.size : nil),
            waiting: identifiers.waiting
          },
          categories_unmapped: (@legacy.category_ids - LegacyIdMap.where(model: "Books::Category").pluck(:legacy_id)).size,
          redirects: redirects.counts,
          legacy_edits_not_synced: (initialized? ? @legacy.books_updated_since(@initialized_at, through_id: @watermarks["books"]) : nil)
        }
      end

      def record_counts(key, model, window, scoped_ids, legacy_ids)
        here_ids = model.where("id < ?", RESERVED_CEILINGS.fetch(TABLES.fetch(key))).pluck(:id)
        {
          legacy: legacy_ids.size,
          here: here_ids.size,
          would_insert: scoped_ids.size - model.where(id: scoped_ids.to_a).count,
          waiting: window.waiting,
          skipped_redirected: window.ids.size - scoped_ids.size,
          legacy_deleted_still_here: (here_ids - legacy_ids).sort
        }
      end
    end
  end
end
