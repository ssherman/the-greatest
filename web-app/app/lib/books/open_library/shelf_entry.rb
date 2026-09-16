# frozen_string_literal: true

module Books
  module OpenLibrary
    # One row of an author's shelf, as served by `GET /authors/{key}/works`
    # (popularity-ordered, paginated by the caller's limit/offset).
    ShelfEntry = Data.define(
      :key, :source, :title, :readinglog_count, :edition_count,
      :ratings_count, :declared_year
    ) do
      def self.from_record(record)
        new(
          key: record.dig("key", "key"),
          source: record.dig("key", "source"),
          title: record["title"],
          readinglog_count: record["readinglog_count"],
          edition_count: record["edition_count"],
          ratings_count: record["ratings_count"],
          declared_year: record["declared_year"]
        )
      end
    end
  end
end
