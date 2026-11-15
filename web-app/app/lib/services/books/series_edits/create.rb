# frozen_string_literal: true

module Services
  module Books
    module SeriesEdits
      # Creates a series, optionally with an admin-sourced Goodreads series id. The id
      # check looks across every series, soft-deleted ones included, so a deleted series
      # keeps the id from being claimed twice.
      class Create
        def self.call(attrs:)
          new(attrs).call
        end

        def initialize(attrs)
          @attrs = attrs
        end

        def call
          title = @attrs["title"]
          return failure("Title can't be blank.") if title.blank?

          goodreads_id = nil
          if @attrs.key?("goodreads_series_id")
            goodreads_id = @attrs["goodreads_series_id"].to_s
            return failure("goodreads_series_id must not be blank.") if goodreads_id.blank?
            return failure("goodreads_series_id must be the digits from the series URL (goodreads.com/series/<digits>-name).") unless goodreads_id.match?(/\A\d+\z/)
          end

          ::Books::Series.transaction do
            if goodreads_id
              GoodreadsIdLock.acquire(goodreads_id)
              other = GoodreadsIdLock.holder_of(goodreads_id)
              if other
                next failure("Goodreads series id #{goodreads_id} already belongs to series #{other.identifiable_id}.")
              end
            end

            series = ::Books::Series.create!(title: title)
            series.identifiers.create!(identifier_type: :books_series_goodreads_id, value: goodreads_id, source: :admin) if goodreads_id
            Result.new(success?: true, data: series, errors: [])
          end
        rescue ActiveRecord::RecordInvalid => e
          failure(e.record.errors.full_messages.join(", "))
        end

        private

        def failure(message)
          Result.new(success?: false, errors: [message], code: :unprocessable)
        end
      end
    end
  end
end
