# frozen_string_literal: true

module Services
  module Books
    module GoodreadsRebuild
      # The stage one survey, pass 1 (rebuild spec §4): every derived book,
      # by id, through SurveyBook. Local only: it reads export rows and our
      # catalog and calls no outside service, so it can run alongside a
      # verification run. Without resurvey it takes only books with no survey, so
      # an interrupted run picks up where it stopped. Rows are loaded a batch
      # at a time, with a book's rows on merged-away legacy ids included.
      class Survey
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        BATCH = 500
        # Session advisory lock key: one survey run at a time. The
        # verification run holds 7_262_024_100_801.
        LOCK_KEY = 7_262_024_100_802
        LOCK_BUSY = "another survey run is in progress"

        def self.call(limit:, resurvey: false, batch_size: BATCH)
          new(limit: limit, resurvey: resurvey, batch_size: batch_size).call
        end

        def initialize(limit:, resurvey:, batch_size:)
          @limit = limit
          @resurvey = resurvey
          @batch_size = batch_size
        end

        def call
          ::ActiveRecord::Base.connection_pool.with_connection do |connection|
            unless connection.select_value("SELECT pg_try_advisory_lock(#{LOCK_KEY})")
              return Result.new(success?: false, data: {processed: 0, stopped: true, error: LOCK_BUSY}, errors: [LOCK_BUSY])
            end

            begin
              Result.new(success?: true, data: {processed: run, stopped: false, error: nil}, errors: [])
            ensure
              connection.select_value("SELECT pg_advisory_unlock(#{LOCK_KEY})")
            end
          end
        end

        private

        def run
          map = LegacyBookMap.build
          processed = 0
          scope.in_batches(of: @batch_size) do |batch|
            books = batch.includes(:authors).to_a
            rows = ::Books::GoodreadsImportRow.where(legacy_book_id: map.all_legacy_ids_for(books.map(&:id)))
              .includes(:goodreads_edition).group_by(&:legacy_book_id)
            books.each do |book|
              SurveyBook.call(book: book, rows: map.legacy_ids_for(book.id).flat_map { |id| rows.fetch(id, []) })
            end
            processed += books.size
            Rails.logger.info("Goodreads rebuild survey: #{processed} books")
          end
          processed
        end

        def scope
          books = Cohort.derived
          books = books.where.not(id: ::Books::RebuildBookSurvey.select(:book_id)) unless @resurvey
          books = books.order(:id)
          @limit ? ::Books::Book.where(id: books.limit(@limit).select(:id)) : books
        end
      end
    end
  end
end
