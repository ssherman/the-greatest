# frozen_string_literal: true

module Services
  module Books
    module SeriesEdits
      # Soft-deletes a series: removes its book links and clears the representative, but
      # keeps the row and its identifiers so a Goodreads id never re-creates it.
      class Delete
        def self.call(series:, dry_run: false)
          new(series, dry_run).call
        end

        def initialize(series, dry_run)
          @series = series
          @dry_run = dry_run
        end

        def call
          return refused if @series.deleted?
          return success(@series.series_books.count) if @dry_run

          book_count = nil
          ::Books::Series.transaction do
            # Re-read under the lock: a concurrent delete or merge may have won.
            @series.lock!
            return refused if @series.deleted?

            book_count = ::Books::SeriesBook.where(series_id: @series.id).delete_all
            @series.update!(deleted: true, representative_book_id: nil)
          end
          success(book_count)
        end

        private

        def success(book_count)
          Result.new(success?: true, data: {series: @series, book_count: book_count}, errors: [])
        end

        def refused
          Result.new(success?: false, errors: ["Series #{@series.id} is already deleted."], code: :unprocessable)
        end
      end
    end
  end
end
