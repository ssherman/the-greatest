module Services
  module Books
    module GoodreadsEnrichment
      # Puts a book into the series Goodreads lists for it. A series is identified only by
      # its Goodreads series id, never by title: unrelated series share titles, and the
      # slug (friendly_id) keeps same-titled rows apart.
      #
      # Find-or-create runs under GoodreadsIdLock, the same advisory lock the admin/API
      # create takes, so concurrent callers can't create two series for one id. Linking
      # locks the series row and re-checks it, so a concurrent Delete or Merge wins
      # cleanly. Series are resolved first and then locked in ascending id order, the
      # order Merge locks in, so a surrounding transaction can't deadlock against it.
      class ApplySeries
        PLAIN_NUMBER = /\A\d+(\.\d+)?\z/

        def self.call(book:, entries:)
          new(book).call(entries)
        end

        def initialize(book)
          @book = book
        end

        def call(entries)
          resolved = Array(entries).map do |entry|
            label = entry["position"].to_s.strip.presence
            if entry["goodreads_series_id"].blank?
              {entry: entry, label: label, fact: fact(entry, label, false, "invalid")}
            else
              series, created = find_or_create_series(entry["goodreads_series_id"], entry["title"])
              if series.nil?
                {entry: entry, label: label, fact: fact(entry, label, false, "deleted_series")}
              else
                {entry: entry, label: label, series: series, created: created}
              end
            end
          end

          # Lock and link in ascending series id order; facts stay in entry order.
          resolved.each_with_index.select { |r, _| r[:series] }.sort_by { |r, i| [r[:series].id, i] }.each do |r, _|
            r[:fact] = link(r[:entry], r[:label], r[:series], r[:created])
          end
          resolved.map { |r| r[:fact] }
        end

        private

        def link(entry, label, series, created)
          # Lock the series row and re-check it: a Delete or Merge may have committed since
          # canonical was resolved, and a link on a deleted series is never cleaned up.
          ::Books::Series.transaction do
            series.lock!
            return fact(entry, label, false, "deleted_series") if series.deleted?

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
          end
          fact(entry, label, true, created ? "created" : "linked")
        end

        def find_or_create_series(goodreads_id, title)
          ::Books::Series.transaction do
            # Same lock the admin/API create takes, so the two can't both claim the id.
            Services::Books::SeriesEdits::GoodreadsIdLock.acquire(goodreads_id)
            identifier = Services::Books::SeriesEdits::GoodreadsIdLock.holder_of(goodreads_id)
            # A merged series resolves to its target; a deleted one (or one merged into a
            # deleted target) resolves to nil, so the caller skips it.
            next [identifier.identifiable.canonical, false] if identifier

            series = ::Books::Series.create!(title: title)
            series.identifiers.create!(identifier_type: :books_series_goodreads_id, value: goodreads_id.to_s, source: :goodreads)
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
