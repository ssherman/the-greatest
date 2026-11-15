# frozen_string_literal: true

module Services
  module Books
    module SeriesEdits
      # Adds, updates and removes a book's link to a live series. attrs keys:
      # "position" (Numeric or nil), "numbered" (Boolean), "position_label" (String or nil).
      # Only the keys present change; a blank position_label is stored as nil.
      class Membership
        ATTRS = %w[position numbered position_label].freeze

        def self.add(series:, book_id:, attrs: {})
          locked(series) do
            next failure("No book #{book_id}.") unless ::Books::Book.exists?(book_id)
            if ::Books::SeriesBook.exists?(series_id: series.id, book_id: book_id)
              next failure("Book #{book_id} is already in this series; edit that entry instead.")
            end

            link = ::Books::SeriesBook.new(series: series, book_id: book_id)
            assign(link, attrs)
            link.save!
            success(link)
          end
        end

        def self.update(series:, book_id:, attrs:)
          locked(series) do
            link = ::Books::SeriesBook.find_by(series_id: series.id, book_id: book_id)
            next not_in_series(book_id) unless link

            assign(link, attrs)
            link.save!
            success(link)
          end
        end

        def self.remove(series:, book_id:)
          locked(series) do
            link = ::Books::SeriesBook.find_by(series_id: series.id, book_id: book_id)
            next not_in_series(book_id) unless link

            series.update!(representative_book_id: nil) if series.representative_book_id == book_id.to_i
            link.destroy!
            success(link)
          end
        end

        class << self
          private

          # Locks the series and re-checks it under the lock, so a concurrent delete or
          # merge can't leave a link on a dead series.
          def locked(series)
            ::Books::Series.transaction do
              series.lock!
              message = Update.edit_refusal(series)
              next failure(message) if message

              yield
            end
          rescue ActiveRecord::RecordInvalid => e
            failure(e.record.errors.full_messages.join(", "))
          end

          def assign(link, attrs)
            attrs = attrs.to_h.stringify_keys
            link.position = attrs["position"] if attrs.key?("position")
            link.numbered = attrs["numbered"] if attrs.key?("numbered")
            link.position_label = attrs["position_label"].presence if attrs.key?("position_label")
          end

          def success(link)
            Result.new(success?: true, data: link, errors: [])
          end

          def failure(message, code = :unprocessable)
            Result.new(success?: false, errors: [message], code: code)
          end

          def not_in_series(book_id)
            failure("Book #{book_id} is not in this series.", :not_found)
          end
        end
      end
    end
  end
end
