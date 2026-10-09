# frozen_string_literal: true

module Services
  module Books
    module OlBackfill
      # Spec section 4, "The job": books one at a time, ranked first, then by
      # how many lists they are on, then id, stopping after `limit` (nil: all).
      # A book whose Open Library lookup raised waits and is tried again;
      # after the last wait it is logged failed and the run stops, so an
      # outage does not use up the batch.
      class Run
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        RETRY_DELAYS = [15, 30, 60, 120, 240, 300].freeze
        BATCH = 100
        # Seconds to wait after a book that used /resolve. The service runs one at a
        # time and turns the others away busy, so this leaves the slot to the wizard,
        # the Goodreads replay and the legacy imports.
        RESOLVE_PAUSE = 4
        # A 4xx that is about this book's data, not about us or the service.
        BOOK_SPECIFIC_STATUSES = [400, 422].freeze
        # Session advisory lock key: one backfill run at a time. A fixed 64-bit
        # constant, not a hash; the app's other advisory locks use hashtext of a
        # string, so this cannot collide with them by accident.
        LOCK_KEY = 7_262_024_100_801
        LOCK_BUSY = "another Open Library backfill run is in progress"

        def self.call(limit:, run_id:, retry_unsure: false, client: nil, sleeper: nil, scope: nil)
          new(limit: limit, run_id: run_id, retry_unsure: retry_unsure, client: client, sleeper: sleeper, scope: scope).call
        end

        def initialize(limit:, run_id:, retry_unsure:, client:, sleeper:, scope:)
          @limit = limit
          @run_id = run_id
          @retry_unsure = retry_unsure
          @client = client || ::Books::OpenLibrary::Client.new
          @sleeper = sleeper || ->(seconds) { sleep(seconds) }
          @scope = scope || ::Books::Book.all
          @attempted = Set.new
        end

        def call
          ::ActiveRecord::Base.connection_pool.with_connection do |connection|
            unless connection.select_value("SELECT pg_try_advisory_lock(#{LOCK_KEY})")
              return Result.new(success?: false, data: {processed: 0, stopped: true, error: LOCK_BUSY}, errors: [LOCK_BUSY])
            end

            begin
              run_locked
            ensure
              release_lock(connection)
            end
          end
        end

        private

        def run_locked
          # A re-queued run (same run id) counts what it already logged
          # (failures aside) toward its limit.
          done = ::Books::OpenLibraryBackfill.where(run_id: @run_id).where.not(outcome: :failed).count
          version = @retry_unsure ? @client.version : nil
          loop do
            break if full?(done)

            ids = next_ids(version, done)
            break if ids.empty?

            ids.each do |id|
              break if full?(done)

              book = ::Books::Book.find_by(id: id)
              next unless book

              outcome = process(book)
              # A :done always wrote a settled row, which next_ids already excludes.
              @attempted << id unless outcome == :done
              case outcome
              when :done then done += 1
              when :failed then return finish(done, stopped: true)
              end
            end
          end
          finish(done, stopped: false)
        rescue ::Books::OpenLibrary::Exceptions::Error => e
          @error = "#{e.class}: #{e.message}"
          finish(done || 0, stopped: true)
        end

        # Never raises: it runs in an ensure and must not mask the run's own error.
        def release_lock(connection)
          return if unlock(connection)

          ::Rails.logger.warn("Open Library backfill run #{@run_id}: advisory lock was already lost at the end of the run")
        rescue => e
          ::Rails.logger.warn("Open Library backfill run #{@run_id}: releasing the advisory lock failed: #{e.class}: #{e.message}")
        end

        def unlock(connection) = connection.select_value("SELECT pg_advisory_unlock(#{LOCK_KEY})")

        def full?(done) = !@limit.nil? && done >= @limit

        def finish(done, stopped:)
          Result.new(success?: !stopped, data: {processed: done, stopped: stopped, error: @error}, errors: [@error].compact)
        end

        # :done, :skipped (another run wrote the row, or this book alone failed:
        # the run goes on) or :failed (an outage: the run stops).
        def process(book)
          attempt = 0
          begin
            result = ApplyBook.call(book: book, client: @client, run_id: @run_id)
            return :skipped unless result.success?

            @sleeper.call(RESOLVE_PAUSE) if result.data&.via_resolve?
            :done
          rescue ::Books::OpenLibrary::Exceptions::Error => e
            if book_specific?(e)
              # This book fails the same way every time: log it, move on.
              ApplyBook.record_failure(book: book, run_id: @run_id, error: "#{e.class}: #{e.message}")
              return :skipped
            end

            delay = RETRY_DELAYS[attempt]
            if delay
              attempt += 1
              @sleeper.call(delay)
              retry
            end
            @error = "#{e.class}: #{e.message}"
            ApplyBook.record_failure(book: book, run_id: @run_id, error: @error)
            :failed
          end
        end

        def book_specific?(error)
          error.is_a?(::Books::OpenLibrary::Exceptions::ParseError) ||
            (error.is_a?(::Books::OpenLibrary::Exceptions::ClientError) && BOOK_SPECIFIC_STATUSES.include?(error.status_code))
        end

        def next_ids(version, done)
          size = @limit.nil? ? BATCH : [BATCH, @limit - done].min
          failed = ::Books::OpenLibraryBackfill.outcomes["failed"]
          settled = ::Books::OpenLibraryBackfill.where.not(outcome: :failed)
          settled = settled.where.not(id: retryable_unsure(version)) if version
          config_id = ::Books::RankingConfiguration.default_primary&.id

          scope = @scope.where.not(id: settled.select(:book_id))
          scope = scope.where.not(id: @attempted.to_a) if @attempted.any?
          scope
            .joins("LEFT JOIN books_open_library_backfills prior ON prior.book_id = books_books.id")
            .joins(::Books::Book.sanitize_sql_array([
              "LEFT JOIN ranked_items ranked ON ranked.item_type = 'Books::Book' AND ranked.item_id = books_books.id " \
              "AND ranked.ranking_configuration_id = ? AND ranked.rank IS NOT NULL", config_id
            ]))
            .joins("LEFT JOIN (SELECT listable_id, COUNT(*) AS list_count FROM list_items " \
                   "WHERE listable_type = 'Books::Book' GROUP BY listable_id) list_counts ON list_counts.listable_id = books_books.id")
            .order(Arel.sql(::Books::Book.sanitize_sql_array([
              "COALESCE(prior.outcome = ?, false) ASC, ranked.rank ASC NULLS LAST, " \
              "list_counts.list_count DESC NULLS LAST, books_books.id ASC", failed
            ])))
            .limit(size)
            .pluck("books_books.id")
        end

        def retryable_unsure(version)
          ::Books::OpenLibraryBackfill.unsure
            .where("dump_date < :dump OR matcher_version < :matcher", dump: version[:dump_date].to_s, matcher: version[:matcher_version].to_i)
            .select(:id)
        end
      end
    end
  end
end
