# frozen_string_literal: true

module Services
  module Books
    # Books similar to a given book: runs the OpenSearch similarity query, caps
    # how many can share an author, and loads the records the views need.
    class SimilarBooks
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(book, **options)
        new(book, **options).call
      end

      def initialize(book, **options)
        @book = book
        @options = options
        @config = Rails.application.config.x.book_similarity.merge(options)
      end

      def call
        hits = ::Search::Books::Search::BookSimilar.call(@book, @options)
        return empty if hits.empty?

        qualified = apply_author_cap(hits, load_books(hits))

        Result.new(
          success?: true,
          data: {books: qualified.first(limit), more_available: qualified.size > limit},
          errors: []
        )
      rescue => e
        # A search outage costs the card, not the page.
        Rails.logger.error "SimilarBooks failed for book #{@book.id}: #{e.message}"
        empty
      end

      private

      def limit
        @config[:limit]
      end

      # Root-anchored: inside Services::Books a bare `Books::Book` resolves to
      # Services::Books::Book and raises a confusing NameError.
      #
      # The image chain matters -- the similar page renders 25 CardComponents and
      # each one reads primary_image. Without it that is a 25-query N+1.
      def load_books(hits)
        ::Books::Book
          .where(id: hits.map { |hit| hit[:id].to_i })
          .includes(book_authors: :author)
          .includes(primary_image: {file_attachment: {blob: {variant_records: {image_attachment: :blob}}}})
          .index_by(&:id)
      end

      # An author's other books genuinely share nearly all the same categories, so
      # they win on merit and can fill the whole panel. Only a cap changes that --
      # the tiny same-author boost in the query is not what causes the domination.
      #
      # Deliberately does not stop at `limit`: running the cap across every
      # over-fetched hit is what makes more_available a fact rather than a guess.
      def apply_author_cap(hits, books_by_id)
        max = @config[:max_per_author]
        counts = Hash.new(0)

        hits.filter_map do |hit|
          book = books_by_id[hit[:id].to_i]
          next unless book

          author_ids = book.book_authors.map(&:author_id)
          next if author_ids.any? { |id| counts[id] >= max }

          author_ids.each { |id| counts[id] += 1 }
          book
        end
      end

      def empty
        Result.new(success?: true, data: {books: [], more_available: false}, errors: [])
      end
    end
  end
end
