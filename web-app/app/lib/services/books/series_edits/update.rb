# frozen_string_literal: true

module Services
  module Books
    module SeriesEdits
      # Updates a live series. Only the keys present in attrs change: "title",
      # "representative_book_id" (a book in the series, or nil to clear) and
      # "goodreads_series_id" (only while the series has none).
      class Update
        def self.call(series:, attrs:)
          new(series, attrs).call
        end

        def initialize(series, attrs)
          @series = series
          @attrs = attrs
        end

        def call
          ::Books::Series.transaction do
            # Re-read under the lock: a concurrent delete or merge may have won.
            @series.lock!
            message = Update.edit_refusal(@series)
            next failure(message) if message

            apply
          end
        rescue ActiveRecord::RecordInvalid => e
          failure(e.record.errors.full_messages.join(", "))
        end

        def self.edit_refusal(series)
          return "Series #{series.id} was merged into series #{series.merged_into_id}." if series.merged_into_id
          "Series #{series.id} is deleted." if series.deleted?
        end

        private

        def apply
          if @attrs.key?("representative_book_id")
            book_id = @attrs["representative_book_id"]
            if book_id && !::Books::SeriesBook.exists?(series_id: @series.id, book_id: book_id)
              return failure("Book #{book_id} is not in this series.")
            end
            @series.representative_book_id = book_id
          end

          @series.title = @attrs["title"] if @attrs.key?("title")

          if @attrs.key?("goodreads_series_id")
            error = attach_goodreads_id(@attrs["goodreads_series_id"].to_s)
            return failure(error) if error
          end

          @series.save!
          Result.new(success?: true, data: @series, errors: [])
        end

        def attach_goodreads_id(value)
          existing = @series.identifiers.find_by(identifier_type: :books_series_goodreads_id)
          return "Series #{@series.id} already has Goodreads series id #{value}." if existing
          if (other = Create.holder_of(value))
            return "Goodreads series id #{value} already belongs to series #{other.identifiable_id}."
          end

          @series.identifiers.create!(identifier_type: :books_series_goodreads_id, value: value, source: :admin)
          nil
        end

        def failure(message)
          Result.new(success?: false, errors: [message], code: :unprocessable)
        end
      end
    end
  end
end
