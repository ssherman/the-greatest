# frozen_string_literal: true

# The books columns (spec §12). `context` runs once per batch of book ids and
# answers every many-to-many column from grouped queries; `row` is pure.
# `row_for_book` exists because the saved-search export hydrates books rather
# than ranked items and carries the rank on the book itself.
module CsvExports
  module Books
    class RankedBookRow
      URL_HELPERS = Rails.application.routes.url_helpers

      HEADERS = ["Rank", "Score", "ID", "Title", "Authors", "Year", "Original Language", "Countries",
        "Genres", "Subjects", "Locations", "Page Range", "Word Count", "URL"].freeze

      def self.preloads
        [:original_language]
      end

      def self.context(book_ids)
        categories = ::CategoryItem.joins(:category)
          .where(item_type: "Books::Book", item_id: book_ids, categories: {deleted: false})
        types = ::Category.category_types

        {
          # position is NULL on every row of the dev database, so the id tiebreaker
          # is what keeps two exports of the same book byte-identical.
          authors: Aggregate.names(::Books::BookAuthor.joins(:author).where(book_id: book_ids),
            group_by: "books_book_authors.book_id", name: "books_authors.name",
            order: "books_book_authors.position NULLS LAST, books_book_authors.id"),
          countries: Aggregate.names(::Books::BookCountry.joins(:country).where(book_id: book_ids),
            group_by: "books_book_countries.book_id", name: "books_countries.name", order: "books_countries.name"),
          genres: category_names(categories, types[:genre]),
          subjects: category_names(categories, types[:subject]),
          locations: category_names(categories, types[:location])
        }
      end

      def self.row(ranked_item, ctx)
        row_for_book(ranked_item.item, rank: ranked_item.rank, score: ranked_item.score, ctx: ctx)
      end

      def self.row_for_book(book, rank:, score:, ctx:)
        [
          rank,
          format_score(score),
          book.id,
          book.title,
          ctx[:authors][book.id],
          book.first_published_year,
          book.original_language&.name,
          ctx[:countries][book.id],
          ctx[:genres][book.id],
          ctx[:subjects][book.id],
          ctx[:locations][book.id],
          book.page_range,
          book.word_count,
          "#{Api::Host.base_url(:books)}#{URL_HELPERS.book_path(book)}"
        ]
      end

      def self.format_score(score)
        score.nil? ? nil : format("%.2f", score)
      end

      def self.category_names(scope, category_type)
        Aggregate.names(scope.where(categories: {category_type: category_type}),
          group_by: "category_items.item_id", name: "categories.name", order: "categories.name")
      end
      private_class_method :category_names
    end
  end
end
