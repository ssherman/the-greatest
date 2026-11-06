# frozen_string_literal: true

module Services
  module Books
    module Verification
      # Spec section 4, "The job": books one at a time, ranked first, then by
      # how many lists they are on, then id, stopping after `limit` (nil: all).
      # By default only ranked pre_import books are taken; flags widen that
      # (post_import, unranked) or pick books to redo (retry_unsure, recheck,
      # reharvest, second_chance, redo). trusted leaves out the Goodreads
      # rebuild's derived books (import-made, on no real list): their titles
      # and authors are legacy's until the rebuild repairs them.
      # Each book goes through VerifyBook, which resumes at its stored stage.
      # A book whose Open Library or WorldCat call raised waits and is tried
      # again; after the last wait the run stops (the book keeps its stage), so
      # an outage does not use up the batch.
      class Run
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        RETRY_DELAYS = [15, 30, 60, 120, 240, 300].freeze
        BATCH = 100
        FLAGS = %w[post_import unranked trusted retry_unsure recheck reharvest second_chance redo].freeze
        # Seconds to wait after a book that used /resolve. The service runs one at a
        # time and turns the others away busy, so this leaves the slot to the wizard,
        # the Goodreads replay and the legacy imports.
        RESOLVE_PAUSE = 4
        # A 4xx that is about this book's data, not about us or the service.
        BOOK_SPECIFIC_STATUSES = [400, 422].freeze
        # Any other error is recorded on the book's row and the run goes on,
        # so one book's bad data cannot end a days-long run ("Twelfth Night"
        # held as an ISBN-13 did, silently: the job has no retries). This many
        # in a row is not one book's data: the run stops.
        UNEXPECTED_ERROR_LIMIT = 3
        # Session advisory lock key: one verification run at a time. A fixed 64-bit
        # constant, not a hash; the app's other advisory locks use hashtext of a
        # string, so this cannot collide with them by accident.
        LOCK_KEY = 7_262_024_100_801
        LOCK_BUSY = "another verification run is in progress"

        def self.call(limit:, run_id:, flags: [], client: nil, wc_client: nil, sleeper: nil, scope: nil)
          new(limit: limit, run_id: run_id, flags: flags, client: client, wc_client: wc_client, sleeper: sleeper, scope: scope).call
        end

        def initialize(limit:, run_id:, flags:, client:, wc_client:, sleeper:, scope:)
          flags = Array(flags).map(&:to_s)
          unknown = flags - FLAGS
          raise ArgumentError, "unknown flags: #{unknown.join(", ")}" if unknown.any?
          raise ArgumentError, "redo needs a scope: the books to redo" if flags.include?("redo") && scope.nil?

          @limit = limit
          @run_id = run_id
          @post_import = flags.include?("post_import")
          @unranked = flags.include?("unranked")
          @trusted = flags.include?("trusted")
          @retry_unsure = flags.include?("retry_unsure")
          @recheck = flags.include?("recheck")
          @reharvest = flags.include?("reharvest")
          @second_chance = flags.include?("second_chance")
          @redo = flags.include?("redo")
          @client = client || ::Books::OpenLibrary::Client.new
          @wc_client = wc_client || ::Books::WorldCat::Client.new
          @sleeper = sleeper || ->(seconds) { sleep(seconds) }
          @scope = scope || ::Books::Book.all
          @attempted = Set.new
          @unexpected_in_a_row = 0
        end

        def call
          ::ActiveRecord::Base.connection_pool.with_connection do |connection|
            unless lock_query(connection, "pg_try_advisory_lock")
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
          # A re-queued run (same run id) counts the books it already finished
          # toward its limit. A row it left mid-stage is not finished: it is
          # resumed and counted when it gets to `done`, as in-run.
          done = ::Books::Verification.stage_done.where(run_id: @run_id).where.not(work_outcome: :failed).count
          @version = @retry_unsure ? @client.version : nil
          @wc_dump_date = @wc_client.version[:dump_date]
          loop do
            break if full?(done)

            ids = next_ids(@version, done)
            break if ids.empty?

            ids.each do |id|
              break if full?(done)

              book = ::Books::Book.find_by(id: id)
              next unless book

              outcome = process(book)
              # A book is tried once per call, whatever came of it, so a row that
              # does not reach `done` can never keep the loop on one book.
              @attempted << id
              case outcome
              when :done then done += 1
              when :failed then return finish(done, stopped: true)
              end
            end
          end
          finish(done, stopped: false)
        rescue ::Books::OpenLibrary::Exceptions::Error, ::Books::WorldCat::Exceptions::Error => e
          @error = "#{e.class}: #{e.message}"
          finish(done || 0, stopped: true)
        end

        # Never raises: it runs in an ensure and must not mask the run's own error.
        def release_lock(connection)
          return if unlock(connection)

          ::Rails.logger.warn("Verification run #{@run_id}: advisory lock was already lost at the end of the run")
        rescue => e
          ::Rails.logger.warn("Verification run #{@run_id}: releasing the advisory lock failed: #{e.class}: #{e.message}")
        end

        def unlock(connection) = lock_query(connection, "pg_advisory_unlock")

        # Uncached: inside the Rails executor (every job, every test) select_value is
        # answered from the query cache, so a second identical lock or unlock never
        # reaches the server and the lock leaks silently.
        def lock_query(connection, function)
          connection.uncached { connection.select_value("SELECT #{function}(#{LOCK_KEY})") }
        end

        def full?(done) = !@limit.nil? && done >= @limit

        def finish(done, stopped:)
          Result.new(success?: !stopped, data: {processed: done, stopped: stopped, error: @error}, errors: [@error].compact)
        end

        # :done, :skipped (another run wrote the row, or this book alone failed:
        # the run goes on) or :failed (an outage: the run stops).
        def process(book)
          attempt = 0
          begin
            prepare(book)
            result = VerifyBook.call(book: book, ol_client: @client, wc_client: @wc_client, run_id: @run_id, wc_dump_date: @wc_dump_date)
            # Any outcome but an unexpected error ends a run of them.
            @unexpected_in_a_row = 0
            return :skipped unless result.success?

            @sleeper.call(RESOLVE_PAUSE) if result.data&.via_resolve
            :done
          rescue ::Books::OpenLibrary::Exceptions::Error, ::Books::WorldCat::Exceptions::Error => e
            if book_specific?(e)
              @unexpected_in_a_row = 0
              # This book fails the same way every time: log it, move on.
              record_stop(book, "#{e.class}: #{e.message}")
              return :skipped
            end

            delay = RETRY_DELAYS[attempt]
            if delay
              attempt += 1
              @sleeper.call(delay)
              retry
            end
            @error = "#{e.class}: #{e.message}"
            record_stop(book, @error)
            :failed
          rescue => e
            unexpected(book, e)
          end
        end

        def unexpected(book, error)
          message = "#{error.class}: #{error.message}"
          ::Rails.logger.error("Verification run #{@run_id}: book #{book.id}: #{message}\n#{Array(error.backtrace).first(15).join("\n")}")
          record_stop(book, message)
          @unexpected_in_a_row += 1
          return :skipped if @unexpected_in_a_row < UNEXPECTED_ERROR_LIMIT

          @error = message
          :failed
        end

        # Stage 1 failing logs the book failed, as before; a later stage keeps
        # the row's stage and records why it stopped.
        def record_stop(book, message)
          row = ::Books::Verification.find_by(book_id: book.id)
          if row.nil? || row.stage_work?
            ApplyBook.record_failure(book: book, run_id: @run_id, error: message)
          else
            row.update!(stage_error: message.truncate(1000), run_id: @run_id)
          end
        end

        # A done row picked up by second_chance starts over at stage 1 and keeps
        # a record of what it was; that check comes first because its reset
        # covers what retry_unsure and recheck would do. One picked up by
        # retry_unsure also starts over at stage 1; one picked up by recheck
        # re-runs from the editions (settled work) or WorldCat (no settled
        # work); one picked up by reharvest re-runs from the editions. Same
        # predicates as next_ids.
        def prepare(book)
          # A redo starts over at stage 1, reverted rows included: the redo's
          # caller reverted the book first (books:verify_keep_bigger). The row
          # becomes one ApplyBook reprocesses (unsure, or removed, which stays
          # removed if nothing settles), not one it takes as settled.
          if @redo && redoable.where(book_id: book.id).exists?
            row = ::Books::Verification.find_by(book_id: book.id)
            row.update!(stage: :work, work_outcome: row.removed? ? :removed : :unsure)
            return
          end

          row = ::Books::Verification.stage_done.where.not(work_outcome: :reverted).find_by(book_id: book.id)
          return unless row

          if @second_chance && second_chanceable.where(book_id: book.id).exists?
            # The earliest record stays: a row taken twice keeps its first
            # second_chance_at, prior_outcome and prior_keys.
            record = row.second_chance_at ? {} : {
              second_chance_at: Time.current,
              prior_outcome: ::Books::Verification.work_outcomes[row.work_outcome],
              prior_keys: ::Identifier.where(identifiable: book, identifier_type: :books_work_openlibrary_id).pluck(:value)
            }
            row.update!(stage: :work, **record)
          elsif @retry_unsure && @version && retryable_unsure(@version).where(book_id: book.id).exists?
            row.update!(stage: :work)
          elsif @recheck && recheckable.where(book_id: book.id).exists?
            row.update!(stage: ::Books::Verification::SETTLED_FOR_EDITIONS.include?(row.work_outcome) ? :identifiers : :worldcat)
          elsif @reharvest && reharvestable.where(book_id: book.id).exists?
            row.update!(stage: :identifiers)
          end
        end

        def book_specific?(error)
          namespace = error.class.module_parent
          return false unless [::Books::OpenLibrary::Exceptions, ::Books::WorldCat::Exceptions].include?(namespace)

          # A 404 is about this book: Open Library 404s a work's editions when a
          # dump refresh removed the key. Retrying cannot help and would wedge every run.
          error.is_a?(namespace::ParseError) || error.is_a?(namespace::NotFoundError) ||
            (error.is_a?(namespace::ClientError) && BOOK_SPECIFIC_STATUSES.include?(error.status_code))
        end

        def next_ids(version, done)
          size = @limit.nil? ? BATCH : [BATCH, @limit - done].min
          failed = ::Books::Verification.work_outcomes["failed"]
          finished = ::Books::Verification.stage_done.or(::Books::Verification.where(work_outcome: :reverted))
          finished = finished.where.not(id: retryable_unsure(version)) if version
          finished = finished.where.not(id: recheckable) if @recheck
          finished = finished.where.not(id: reharvestable) if @reharvest
          finished = finished.where.not(id: second_chanceable) if @second_chance
          finished = finished.where.not(id: redoable) if @redo
          config_id = ::Books::RankingConfiguration.default_primary&.id

          scope = @scope.where.not(id: finished.select(:book_id))
          scope = scope.where.not(id: @attempted.to_a) if @attempted.any?
          scope = scope.where.not(id: Cohort.post_import_range) unless @post_import
          scope = scope.where.not(id: ::Services::Books::GoodreadsRebuild::Cohort.derived.select(:id)) if @trusted
          ranked_join = @unranked ? "LEFT JOIN" : "INNER JOIN"
          scope
            .joins("LEFT JOIN books_verifications prior ON prior.book_id = books_books.id")
            .joins(::Books::Book.sanitize_sql_array([
              "#{ranked_join} ranked_items ranked ON ranked.item_type = 'Books::Book' AND ranked.item_id = books_books.id " \
              "AND ranked.ranking_configuration_id = ? AND ranked.rank IS NOT NULL", config_id
            ]))
            .joins("LEFT JOIN (SELECT listable_id, COUNT(*) AS list_count FROM list_items " \
                   "WHERE listable_type = 'Books::Book' GROUP BY listable_id) list_counts ON list_counts.listable_id = books_books.id")
            .order(Arel.sql(::Books::Book.sanitize_sql_array([
              "COALESCE(prior.work_outcome = ?, false) ASC, ranked.rank ASC NULLS LAST, " \
              "list_counts.list_count DESC NULLS LAST, books_books.id ASC", failed
            ])))
            .limit(size)
            .pluck("books_books.id")
        end

        def recheckable
          ::Books::Verification.stage_done.where.not(work_outcome: :reverted).where(<<~SQL.squish).select(:id)
            EXISTS (SELECT 1 FROM identifiers i WHERE i.identifiable_type = 'Books::Book'
              AND i.identifiable_id = books_verifications.book_id AND i.source = #{::Identifier.sources[:legacy]}
              AND i.created_at > books_verifications.checked_at)
          SQL
        end

        # Done before stage 2 harvested a book's duplicate works: a settled work
        # and a duplicate work key Open Library gave. A row this run already
        # finished is not taken again, so a re-queued run does not redo it.
        def reharvestable
          ::Books::Verification.stage_done.where(work_outcome: ::Books::Verification::SETTLED_FOR_EDITIONS)
            .where.not(run_id: @run_id).where(<<~SQL.squish).select(:id)
              EXISTS (SELECT 1 FROM identifiers i WHERE i.identifiable_type = 'Books::Book'
                AND i.identifiable_id = books_verifications.book_id
                AND i.identifier_type = #{::Identifier.identifier_types[:books_work_openlibrary_duplicate_id]}
                AND i.source = #{::Identifier.sources[:open_library]})
            SQL
        end

        # Done unsure or removed by an earlier run. A row this run already
        # finished is not taken again, so a re-queued run does not redo it.
        # redo: every done row in the run's scope (which is how a redo names its
        # books), reverted ones included, that this run has not finished.
        def redoable
          ::Books::Verification.stage_done.where(book_id: @scope.select(:id)).where.not(run_id: @run_id).select(:id)
        end

        def second_chanceable
          ::Books::Verification.stage_done.where(work_outcome: %i[unsure removed]).where.not(run_id: @run_id).select(:id)
        end

        def retryable_unsure(version)
          ::Books::Verification.unsure
            .where("dump_date < :dump OR matcher_version < :matcher", dump: version[:dump_date].to_s, matcher: version[:matcher_version].to_i)
            .select(:id)
        end
      end
    end
  end
end
