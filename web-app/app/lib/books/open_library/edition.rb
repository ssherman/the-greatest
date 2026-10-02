# frozen_string_literal: true

module Books
  module OpenLibrary
    # One EditionRecord as served by `GET /works/{key}/editions`. No
    # source_version of its own: editions only ever arrive as part of an
    # enveloped list, and the envelope's source_version covers the whole
    # response.
    Edition = Data.define(
      :key, :source, :title, :subtitle, :publish_year, :publish_date_raw,
      :language_code, :page_count, :publisher, :physical_format, :edition_name,
      :series, :isbn13, :isbn10, :oclc, :lccn, :asin, :goodreads
    ) do
      def self.from_record(record)
        new(
          key: record.dig("key", "key"),
          source: record.dig("key", "source"),
          title: record["title"],
          subtitle: record["subtitle"],
          publish_year: record["publish_year"],
          publish_date_raw: record["publish_date_raw"],
          language_code: record["language_code"],
          page_count: record["page_count"],
          publisher: record["publisher"],
          physical_format: record["physical_format"],
          edition_name: record["edition_name"],
          series: record["series"] || [],
          isbn13: record["isbn13"] || [],
          isbn10: record["isbn10"] || [],
          oclc: record["oclc"] || [],
          lccn: record["lccn"] || [],
          asin: record["asin"] || [],
          goodreads: record["goodreads"] || []
        )
      end
    end
  end
end
