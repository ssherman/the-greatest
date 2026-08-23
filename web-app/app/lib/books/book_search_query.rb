# frozen_string_literal: true

module Books
  # Runs the public site search: one OpenSearch full-text query, then one
  # Postgres round trip to hydrate the hits.
  #
  # Ordering is OpenSearch's, not Postgres': an IN clause cannot reproduce
  # relevance order, so the ids are re-applied after loading. An id the index
  # still carries but Postgres no longer has is dropped rather than raising --
  # a book deleted without a reindex should cost one result, not the page.
  #
  # Every book carries `ranked_position` from the default primary ranking
  # configuration so Books::CardComponent renders the same #N badge it does on
  # the homepage. An unranked match simply has no badge.
  class BookSearchQuery
    DEFAULT_SIZE = 50

    def self.call(text, size: DEFAULT_SIZE)
      return [] if text.blank?

      hits = ::Search::Books::Search::BookGeneral.call(text, size: size)
      hydrate(hits.map { |hit| hit[:id].to_i }.uniq)
    end

    # The join is written out rather than using `includes(:primary_ranked_item)`
    # because the rank has to come from the default primary specifically, and a
    # LEFT JOIN keeps unranked matches in the result set.
    def self.hydrate(ids)
      return [] if ids.empty?

      rc = ::Books::RankingConfiguration.default_primary
      return [] if rc.nil?

      books = ::Books::Book
        .where(id: ids)
        .select("books_books.*, ranked_items.rank AS ranked_position")
        .joins(
          "LEFT OUTER JOIN ranked_items ON ranked_items.item_id = books_books.id " \
          "AND ranked_items.item_type = 'Books::Book' " \
          "AND ranked_items.ranking_configuration_id = #{rc.id.to_i}"
        )
        .preload(book_authors: :author, primary_image: {file_attachment: :blob})
        .index_by(&:id)

      ids.filter_map { |id| books[id] }
    end

    private_class_method :hydrate
  end
end
