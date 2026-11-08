# frozen_string_literal: true

module Services
  module Books
    # Books similar to a given book: runs the OpenSearch similarity query, caps
    # how many can share an author, and loads the records the views need.
    class SimilarBooks
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      # `raise_on_failure: true` re-raises a failed search instead of answering
      # an empty success, for a caller (the API) that must tell "no similar
      # books" from "search is down". The site's book page leaves it off and
      # keeps its silent empty card. It is the service's own option: it never
      # reaches the similarity query or the merged config.
      def self.call(book, raise_on_failure: false, **options)
        new(book, raise_on_failure: raise_on_failure, **options).call
      end

      def initialize(book, raise_on_failure: false, **options)
        @book = book
        @raise_on_failure = raise_on_failure
        @options = options
        @config = Rails.application.config.x.book_similarity.merge(options)
      end

      def call
        hits = ::Search::Books::Search::BookSimilar.call(@book, @options)
        return empty if hits.empty?

        qualified = apply_author_cap(hits, load_books(hits))

        Result.new(
          success?: true,
          data: {books: qualified.first(limit), more_available: more_available?(qualified, hits)},
          errors: []
        )
      rescue => e
        # A search outage costs the card, not the page. The breadth of this
        # rescue is deliberate -- it is what makes the pre-reindex deploy window
        # (see Search::Books::Search::BookSimilar, similarity_category_count
        # absent from the mapping) degrade gracefully instead of raising. Do not
        # narrow it. But that same breadth also catches a genuine NoMethodError
        # in load_books/apply_author_cap, so log enough to tell the three apart:
        # class and a short backtrace, not just the message.
        Rails.logger.error "SimilarBooks failed for book #{@book.id}: #{e.class}: #{e.message} #{e.backtrace&.first(5)&.join(" | ")}"
        raise if @raise_on_failure

        empty
      end

      private

      def limit
        @config[:limit]
      end

      # The `size` BookSimilar asked OpenSearch for -- read from the same merged
      # config the query itself uses, so this can't drift from what was actually
      # requested.
      def requested_hit_count
        @config[:limit] * @config[:over_fetch]
      end

      # `more_available` should mean "the full similar page would show more than
      # this card does." We can't know that for certain without a second query,
      # so this is a deliberate disjunction, not just "the cap left a surplus":
      # a fully-populated hit window (hits.size >= requested_hit_count) means the
      # author cap may have discarded qualifying books that never even made it
      # into the window we fetched, so we can't rule out more existing beyond it.
      #
      # Erring toward "more" here is the correct trade-off, not a coin flip: if
      # this is wrong, the reader clicks through to a page showing the same
      # books they already saw -- mildly redundant. The failure mode of the
      # alternative is a reader who can never reach results that genuinely
      # exist, because the top of the ranking happened to be dominated by one
      # author -- exactly the case the cap exists to handle in the first place.
      # In practice a full window means there are at least `requested_hit_count`
      # matching books, so the page's larger fetch (limit * over_fetch again,
      # but with page_limit) will almost always yield more after its own cap.
      def more_available?(qualified, hits)
        qualified.size > limit || hits.size >= requested_hit_count
      end

      # Root-anchored: inside Services::Books a bare `Books::Book` resolves to
      # Services::Books::Book and raises a confusing NameError.
      #
      # The image chain matters -- the similar page renders 25 CardComponents and
      # each one reads primary_image. Without it that is a 25-query N+1.
      #
      # `catalog` because the index can lag a book being made provisional;
      # BookSimilar excludes them in the query, but a stale hit must not
      # surface a book awaiting review.
      def load_books(hits)
        ::Books::Book
          .catalog
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
