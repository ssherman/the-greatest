module Services
  module Books
    module GoodreadsEnrichment
      # Puts a book into the series Goodreads lists for it. A series is identified only by
      # its Goodreads series id, never by title: unrelated series share titles, and the
      # slug (friendly_id) keeps same-titled rows apart.
      #
      # Callers run this only on the goodreads_fetch capsule (concurrency 1). The
      # find-then-create below takes no lock, so two concurrent calls for the same new
      # series id could each create one.
      class ApplySeries
        PLAIN_NUMBER = /\A\d+(\.\d+)?\z/

        def self.call(book:, entries:)
          new(book).call(entries)
        end

        def initialize(book)
          @book = book
        end

        def call(entries)
          Array(entries).map { |entry| apply(entry) }
        end

        private

        def apply(entry)
          id = entry["goodreads_series_id"]
          label = entry["position"].to_s.strip.presence
          return fact(entry, label, false, "invalid") if id.blank?

          series, created = find_or_create_series(id, entry["title"])
          link = ::Books::SeriesBook.find_or_initialize_by(series: series, book: @book)
          return fact(entry, label, false, "already_set") if link.persisted?

          if label&.match?(PLAIN_NUMBER)
            link.position = BigDecimal(label)
            link.numbered = true
          else
            link.position = nil
            link.numbered = false
          end
          link.position_label = label
          link.save!
          fact(entry, label, true, created ? "created" : "linked")
        end

        def find_or_create_series(goodreads_id, title)
          identifier = ::Identifier.find_by(
            identifier_type: :books_series_goodreads_id, value: goodreads_id.to_s
          )
          return [identifier.identifiable, false] if identifier

          ::Books::Series.transaction do
            series = ::Books::Series.create!(title: title)
            series.identifiers.find_or_initialize_by(
              identifier_type: :books_series_goodreads_id, value: goodreads_id.to_s
            ).tap { |i|
              i.source = :goodreads
              i.save!
            }
            [series, true]
          end
        end

        def fact(entry, label, applied, reason)
          {
            "series" => entry["title"],
            "goodreads_series_id" => entry["goodreads_series_id"],
            "position" => label,
            "applied" => applied,
            "reason" => reason
          }
        end
      end
    end
  end
end
