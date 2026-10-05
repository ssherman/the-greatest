# frozen_string_literal: true

module Services
  module Books
    module GoodreadsPages
      # Loads the legacy app's scraped Goodreads rows into the page cache
      # (Goodreads import spec §6, "Legacy seed"): about 12k page lookups and
      # 27k search results, all as found pages with source: legacy and no
      # HTML. Their facts about the id are trusted; their legacy link to a
      # Book is not carried over.
      #
      # Every name is role-less: the legacy writers merged translators,
      # illustrators and an export row's own author into one array, so any of
      # them backs an edition, and only the one that agreed becomes an author.
      #
      # Idempotent: an id already cached, fetched or seeded, is never
      # overwritten. Rows with no usable id, title or author are skipped.
      class SeedLegacyPages
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        BATCH = 1_000

        def self.call(records: nil)
          new(records: records).call
        end

        def initialize(records:)
          @records = records || ::LegacyBooks::GoodreadsBook.scraped.find_each(batch_size: BATCH)
        end

        def call
          counts = {inserted: 0, already_present: 0, skipped: 0}
          @records.each_slice(BATCH) do |batch|
            rows = batch.filter_map { |record| attributes_for(record) }
            counts[:skipped] += batch.size - rows.size
            unique = rows.uniq { |row| row[:goodreads_book_id] }
            inserted = unique.any? ? ::Books::GoodreadsPage.insert_all(unique, unique_by: :goodreads_book_id, returning: [:id]).length : 0
            counts[:inserted] += inserted
            counts[:already_present] += rows.size - inserted
          end
          Result.new(success?: true, data: counts, errors: [])
        end

        private

        def attributes_for(record)
          goodreads_book_id = ::Books::GoodreadsId.normalize(record.goodreads_id)&.to_i
          title, series_name, series_number = split_title(record.title, record.series)
          names = Array(record.authors).filter_map { |name| ::Services::Text::NameNormalizer.call(name.to_s).presence }.uniq
          return nil if goodreads_book_id.nil? || title.nil? || names.empty?

          isbn = ::Books::Isbn.normalize(record.isbn13) || ::Books::Isbn.normalize(record.isbn)
          {
            goodreads_book_id: goodreads_book_id,
            source: ::Books::GoodreadsPage.sources[:legacy],
            outcome: ::Books::GoodreadsPage.outcomes[:found],
            fetched_at: record.last_looked_up_at || record.last_refreshed_at,
            title: title,
            # The legacy scraper kept the series name and position, never its id.
            series: series_name ? [{"goodreads_series_id" => nil, "title" => series_name, "position" => series_number}] : [],
            authors: names.map { |name| {"name" => name, "role" => nil, "primary" => false} },
            original_publication_year: record.original_publication_year,
            isbn13: isbn&.isbn13, isbn10: isbn&.isbn10, asin: record.asin.presence
          }
        end

        # A page lookup stored the series apart ("Name #7"); a search result
        # left it on the title ("Title (Name, #7)").
        def split_title(raw_title, raw_series)
          title = ::Services::Text::NameNormalizer.call(raw_title.to_s)
          suffix = ::Books::Goodreads::ExportRow::SERIES_SUFFIX.match(title)
          return [suffix[:title].strip, suffix[:series].strip, suffix[:number].strip] if suffix

          series_name, series_number = raw_series.to_s.strip.split(/\s+#(?=[^#]*\z)/, 2)
          [title.presence, series_name.presence, series_number&.strip.presence]
        end
      end
    end
  end
end
