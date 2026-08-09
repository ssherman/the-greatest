# frozen_string_literal: true

module Books
  # Executes a saved search: resolves the owner's read list, runs the
  # OpenSearch query, hydrates one page from Postgres, and re-applies the
  # order OpenSearch returned.
  #
  # It applies NO filter of its own. OpenSearch sizes the page, so a filter
  # here would remove rows from a page already counted -- short pages under an
  # overstated total. Every criterion lives in BookAdvanced.
  #
  # The one exception is `hydrate`: it drops an id OpenSearch returned but
  # Postgres no longer has, which can happen when a book is deleted without a
  # reindex. That page comes back short of `total`. This is unavoidable given
  # that drift, and failing loudly would be worse than a short page.
  #
  # Returns an array rather than a relation because Postgres cannot reproduce
  # the ranked-then-unranked interleaving from an IN clause.
  class SavedSearchQuery
    # `capped?` because track_total_hits stays at OpenSearch's default of
    # 10,000 (spec §6): past that ceiling it stops counting and reports a lower
    # bound. It answers that from OpenSearch's own `relation` rather than by
    # comparing the total to the ceiling -- a search matching *exactly* 10,000
    # reports "eq" and is an exact total, not a capped one.
    Result = Struct.new(:books, :total, :total_relation, keyword_init: true) do
      def capped?
        total_relation == "gte"
      end
    end

    # The last page OpenSearch can serve: beyond `from + size = MAX_RESULT_WINDOW`
    # there is nothing reachable, so a request past it can 404 without a query.
    def self.max_page(per_page:)
      ::Search::Books::Search::BookAdvanced::MAX_RESULT_WINDOW / per_page
    end

    def self.call(criteria:, owner:, ranking_configuration: nil, page: 1, per_page: 50)
      default = ::Books::RankingConfiguration.default_primary
      rc = ranking_configuration || default
      ensure_default_primary!(rc, default)

      response = ::Search::Books::Search::BookAdvanced.call(
        criteria,
        page: page,
        per_page: per_page,
        excluded_book_ids: criteria.hide_read ? read_book_ids(owner) : []
      )

      Result.new(
        books: hydrate(response[:ids], rc),
        total: response[:total],
        total_relation: response[:total_relation]
      )
    end

    # The index carries only the default primary's ranked_position, so any
    # other configuration would return ranks that silently do not belong to it.
    # The parameter exists so a later increment can build that path without
    # changing this signature.
    def self.ensure_default_primary!(rc, default)
      return if default && rc && rc.id == default.id

      raise ArgumentError,
        "SavedSearchQuery supports only the default primary ranking configuration " \
        "(got #{rc&.id.inspect}, default is #{default&.id.inspect})"
    end

    # hide_read excludes what the search's OWNER has read, not the viewer --
    # legacy passes @search.user as current_user, which keeps a public search's
    # results stable for the person who saved it.
    def self.read_book_ids(owner)
      return [] if owner.nil?

      ::Books::UserList
        .where(user_id: owner.id, list_type: ::Books::SavedSearch.excluded_list_type)
        .joins(:user_list_items)
        .where(user_list_items: {listable_type: "Books::Book"})
        .distinct
        .pluck("user_list_items.listable_id")
    end

    def self.hydrate(ids, rc)
      return [] if ids.empty?

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

    private_class_method :ensure_default_primary!, :read_book_ids, :hydrate
  end
end
