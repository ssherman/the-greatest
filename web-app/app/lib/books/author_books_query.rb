module Books
  # The single place an author's books relation is built, shared by the author
  # pages and the API. Every row carries ranked_position (the book's rank on the
  # given configuration, nil when unranked or when there is no configuration).
  #
  # Ordered ranked books first by rank, then the rest by first_published_year
  # (undated last) and title. books_books.id is the final tie-breaker: duplicate
  # book records are expected, and without a unique key Postgres may order tied
  # rows differently per LIMIT/OFFSET, so a paged listing could repeat or skip one.
  class AuthorBooksQuery
    # ranked_only: true keeps just the books ranked on the configuration (the
    # author page's list); false is the full bibliography. The JOIN is a LEFT
    # OUTER JOIN either way, so unranked books survive in the full list and
    # simply carry a nil ranked_position, which suppresses the rank badge on
    # their card.
    def self.call(author:, ranking_configuration:, ranked_only: false)
      return Books::Book.none if ranking_configuration.nil? && ranked_only

      relation = authored_books(author)
        .preload({book_authors: :author}, {primary_image: {file_attachment: :blob}})

      if ranking_configuration.nil?
        return relation
            .select("books_books.*, NULL::integer AS ranked_position")
            .order(Arel.sql("books_books.first_published_year ASC NULLS LAST"), :title, :id)
      end

      relation = relation
        .select("books_books.*, ranked_items.rank AS ranked_position")
        .joins(
          "LEFT OUTER JOIN ranked_items ON ranked_items.item_id = books_books.id " \
          "AND ranked_items.item_type = 'Books::Book' " \
          "AND ranked_items.ranking_configuration_id = #{ranking_configuration.id.to_i}"
        )
        .order(Arel.sql("ranked_items.rank ASC NULLS LAST, books_books.first_published_year ASC NULLS LAST"), :title, :id)

      relation = relation.where.not(ranked_items: {rank: nil}) if ranked_only
      relation
    end

    # Books the author actually wrote. Books::BookAuthor also carries :editor, and
    # both the ranking aggregation and the index's top-books query already exclude
    # it -- without the same predicate here an author's profile would list edited
    # works as their own while their score ignored them. Provisional books are left
    # out (Goodreads import spec §9).
    def self.authored_books(author)
      author.books.merge(Books::Book.catalog).where(books_book_authors: {role: Books::BookAuthor.roles[:author]})
    end
    private_class_method :authored_books
  end
end
