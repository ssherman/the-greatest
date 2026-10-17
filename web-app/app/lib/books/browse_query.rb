module Books
  # Browse cards must agree with the destination they link to. The destination
  # renders ranked books, so both the gate and the count are ranked: the catalog
  # counter caches (categories.item_count, books_countries.book_count) cover the
  # whole catalog, and gating on them sent 76% of cards to an empty page.
  class BrowseQuery
    TYPES = %w[genre location subject].freeze
    SORTS = %w[book_count name].freeze

    SEARCH_LIMIT = 60
    SEARCH_MIN_LENGTH = 2
    SEARCH_MAX_LENGTH = 100

    def self.categories(ranking_configuration:, type: nil, sort: nil)
      scope = ranked_scope(ranking_configuration)
        .where(category_type: normalized_type(type))

      order_by(scope, sort, "categories.name")
    end

    # Searches all three category types through the same ranked gate and count
    # as the grid, so a hit never disagrees with the page it links to. Results
    # sort by match quality first: past merges left junk alternative_names
    # ("World War I Europe" on Europe), so a name match must beat an alias-only
    # one. Then the current type sorts first rather than filtering the rest out.
    def self.search(ranking_configuration:, query:, type: nil, limit: SEARCH_LIMIT)
      q = query.to_s.strip.first(SEARCH_MAX_LENGTH)
      return Books::Category.none if q.length < SEARCH_MIN_LENGTH

      current_type = ::Category.category_types.fetch(normalized_type(type))
      escaped = Books::Category.sanitize_sql_like(q)

      # The name match runs inside the counting subquery: this is an uncached
      # endpoint hit on every keystroke, and counting ranked books for every
      # category before matching names cost ~760 ms against ~90 ms.
      candidates = Books::Category.active
        .where(::CategorySearchQuery::NAME_OR_ALIAS_SQL, pattern: "%#{escaped}%")
        .select(:id)

      ranked_scope(ranking_configuration, candidate_ids_sql: candidates.to_sql)
        .order(Arel.sql(name_match_quality_sql(escaped)))
        .order(Arel.sql("(categories.category_type = #{current_type.to_i}) DESC"))
        .order("ranked_counts.ranked_count DESC", "categories.name")
        .limit(limit)
    end

    def self.countries(ranking_configuration:, sort: nil)
      scope = Books::Country.filterable
        .joins(<<~SQL)
          INNER JOIN (
            SELECT country_id, COUNT(*) AS ranked_count
            FROM books_book_countries
            WHERE book_id IN (#{ranked_book_ids_sql(ranking_configuration)})
            GROUP BY country_id
          ) ranked_counts ON ranked_counts.country_id = books_countries.id
        SQL
        .select("books_countries.*, ranked_counts.ranked_count")

      order_by(scope, sort, "books_countries.name")
    end

    def self.normalized_type(type)
      TYPES.include?(type.to_s) ? type.to_s : TYPES.first
    end

    def self.normalized_sort(sort)
      SORTS.include?(sort.to_s) ? sort.to_s : SORTS.first
    end

    # Aggregating inside a joined subquery rather than grouping the outer query
    # keeps the result a plain relation: pagy needs count/offset/limit, and
    # .group() breaks count.
    def self.ranked_book_ids_sql(ranking_configuration)
      RankedItem
        .where(ranking_configuration_id: ranking_configuration.id, item_type: "Books::Book")
        .where.not(rank: nil)
        .select(:item_id)
        .to_sql
    end
    private_class_method :ranked_book_ids_sql

    # candidate_ids_sql, when given, limits which categories the subquery counts.
    # It only narrows the rows; each surviving category's count is unchanged.
    # 0 name equals, 1 name starts with, 2 a word in the name starts with,
    # 3 name contains, 4 matched only through alternative_names. Takes the
    # LIKE-escaped query and binds it, so no user text is interpolated.
    def self.name_match_quality_sql(escaped)
      Books::Category.sanitize_sql_array([<<~SQL.squish, {exact: escaped, prefix: "#{escaped}%", word: "% #{escaped}%", any: "%#{escaped}%"}])
        CASE
          WHEN categories.name ILIKE :exact THEN 0
          WHEN categories.name ILIKE :prefix THEN 1
          WHEN categories.name ILIKE :word THEN 2
          WHEN categories.name ILIKE :any THEN 3
          ELSE 4
        END
      SQL
    end
    private_class_method :name_match_quality_sql

    def self.ranked_scope(ranking_configuration, candidate_ids_sql: nil)
      candidate_filter = "AND category_id IN (#{candidate_ids_sql})" if candidate_ids_sql

      scope = Books::Category.active
        .joins(<<~SQL)
          INNER JOIN (
            SELECT category_id, COUNT(*) AS ranked_count
            FROM category_items
            WHERE item_type = 'Books::Book'
              AND item_id IN (#{ranked_book_ids_sql(ranking_configuration)})
              #{candidate_filter}
            GROUP BY category_id
          ) ranked_counts ON ranked_counts.category_id = categories.id
        SQL
        .select("categories.*, ranked_counts.ranked_count")

      # Subject and location cards need a minimum of ranked books (spec §6);
      # one-book categories exist for similarity, not as landing pages.
      scope.where(
        "categories.category_type = :genre OR ranked_counts.ranked_count >= :min",
        genre: ::Category.category_types.fetch("genre"),
        min: Rails.configuration.x.books.browse_min_category_books
      )
    end
    private_class_method :ranked_scope

    def self.order_by(scope, sort, name_column)
      return scope.order(name_column) if normalized_sort(sort) == "name"

      scope.order("ranked_counts.ranked_count DESC", name_column)
    end
    private_class_method :order_by
  end
end
