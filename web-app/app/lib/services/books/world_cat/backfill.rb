# frozen_string_literal: true

module Services
  module Books
    module WorldCat
      # One backfill run: every book with an ISBN-13, in id order, looked up in
      # batches and handed to ApplyCategories. Reruns are safe (ApplyCategories is
      # additive and idempotent). A service failure is retried with backoff; when
      # the retries run out the run STOPS and the books it never reached stay
      # untouched -- a tripped breaker must never look like "done".
      class Backfill
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        LOCK_KEY = 7_203_911_014
        EMPTY_MAP = "genre map has no terms (config/worldcat/genre_map.yml missing or empty)"
        RETRY_DELAYS = [15, 30, 60, 120, 240, 300].freeze

        def self.call(limit:, run_id:, client: nil, map: nil, batch_size: 100, sleeper: nil, scope: nil)
          new(limit:, run_id:, client:, map:, batch_size:, sleeper:, scope:).call
        end

        def initialize(limit:, run_id:, client:, map:, batch_size:, sleeper:, scope:)
          @limit = limit
          @run_id = run_id
          @client = client || ::Books::WorldCat::Client.new
          @map = map || ::Books::WorldCat::GenreMap.load
          @batch_size = batch_size
          @sleeper = sleeper || ->(seconds) { sleep(seconds) }
          @scope = scope
        end

        def call
          return failure(EMPTY_MAP) if @map.size.zero?
          return failure("a WorldCat backfill is already running") unless (@locked = try_lock)

          stats = {processed: 0, matched: 0, genres_linked: 0, audiences_linked: 0, subjects_linked: 0, type_conflicts: 0, subjects_unresolved: Hash.new(0), stopped: false, error: nil}
          books_with_isbns.each_slice(@batch_size) do |slice|
            results = lookup_with_retries(slice.flat_map(&:last).uniq)
            if results.nil?
              stats[:stopped] = true
              break
            end
            slice.each do |book_id, isbns|
              book = ::Books::Book.find_by(id: book_id)
              next if book.nil?

              records = isbns.flat_map { |isbn| results.fetch(isbn, []) }
              outcome = ApplyCategories.call(book: book, records: records, map: @map).data
              stats[:processed] += 1
              stats[:matched] += 1 if outcome[:records].positive?
              stats[:genres_linked] += outcome[:genres_linked].size
              stats[:audiences_linked] += outcome[:audiences_linked].size
              stats[:subjects_linked] += outcome[:subjects_linked].size
              stats[:type_conflicts] += outcome[:type_conflicts]
              outcome[:subjects_unresolved].each { |phrase| stats[:subjects_unresolved][phrase] += 1 }
            end
            Rails.logger.info("WorldCat backfill #{@run_id}: #{stats[:processed]} books, #{stats[:genres_linked]} genre links, #{stats[:audiences_linked]} audience links, #{stats[:type_conflicts]} type conflicts")
          end
          stats[:error] = @last_error&.message
          stats[:subjects_unresolved] = stats[:subjects_unresolved].sort_by { |phrase, n| [-n, phrase] }.to_h
          Result.new(success?: !stats[:stopped], data: stats, errors: stats[:stopped] ? ["stopped: #{stats[:error]}"] : [])
        ensure
          unlock if @locked
        end

        private

        def books_with_isbns
          scope = @scope || ::Identifier
            .where(identifiable_type: "Books::Book", identifier_type: :books_work_isbn13)
            .joins("INNER JOIN books_books ON books_books.id = identifiers.identifiable_id")
            .where.not("books_books.title ~ ?", ::Books::OpenLibrary::EvalExport::E2E_LEFTOVER_TITLE)
          # Same normalisation as VocabularySnapshot: the service answers 422 for a
          # whole batch if ANY ISBN has a bad check digit, so drop those here.
          books = scope.order(:identifiable_id).pluck(:identifiable_id, :value).group_by(&:first).filter_map do |book_id, pairs|
            isbn13s = pairs.filter_map { |_, value| ::Books::Isbn.normalize(value)&.isbn13 }.uniq
            [book_id, isbn13s] if isbn13s.any?
          end
          @limit ? books.first(@limit) : books
        end

        def lookup_with_retries(isbns)
          attempts = 0
          begin
            @client.lookup(isbns)
          rescue ::Books::WorldCat::Exceptions::Error => e
            @last_error = e
            return nil if attempts >= RETRY_DELAYS.size

            @sleeper.call(RETRY_DELAYS[attempts])
            attempts += 1
            retry
          end
        end

        def try_lock
          ::ActiveRecord::Base.connection.uncached do
            ::ActiveRecord::Base.connection.select_value("SELECT pg_try_advisory_lock(#{LOCK_KEY})")
          end
        end

        def unlock
          ::ActiveRecord::Base.connection.execute("SELECT pg_advisory_unlock(#{LOCK_KEY})")
        end

        def failure(message) = Result.new(success?: false, data: nil, errors: [message])
      end
    end
  end
end
