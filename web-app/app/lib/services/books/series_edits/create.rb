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

          goodreads_id = @attrs["goodreads_series_id"].presence&.to_s
          if goodreads_id && (other = Create.holder_of(goodreads_id))
            return failure("Goodreads series id #{goodreads_id} already belongs to series #{other.identifiable_id}.")
          end

          series = nil
          ::Books::Series.transaction do
            series = ::Books::Series.create!(title: title)
            series.identifiers.create!(identifier_type: :books_series_goodreads_id, value: goodreads_id, source: :admin) if goodreads_id
          end
          Result.new(success?: true, data: series, errors: [])
        rescue ActiveRecord::RecordInvalid => e
          failure(e.record.errors.full_messages.join(", "))
        end

        def self.holder_of(value)
          ::Identifier.find_by(identifier_type: :books_series_goodreads_id, value: value.to_s)
        end

        private

        def failure(message)
          Result.new(success?: false, errors: [message], code: :unprocessable)
        end
      end
    end
  end
end
