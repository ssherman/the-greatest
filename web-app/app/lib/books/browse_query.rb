module Books
  # Browse cards must agree with the destination they link to. The destination
  # renders ranked books, so both the gate and the count are ranked: the catalog
  # counter caches (categories.item_count, books_countries.book_count) cover the
  # whole catalog, and gating on them sent 76% of cards to an empty page.
  class BrowseQuery
    TYPES = %w[genre location subject].freeze
    SORTS = %w[book_count name].freeze

    def self.categories(ranking_configuration:, type: nil, sort: nil)
      scope = Books::Category.active
        .where(category_type: normalized_type(type))
        .joins(<<~SQL)
          INNER JOIN (
            SELECT category_id, COUNT(*) AS ranked_count
            FROM category_items
            WHERE item_type = 'Books::Book'
              AND item_id IN (#{ranked_book_ids_sql(ranking_configuration)})
            GROUP BY category_id
          ) ranked_counts ON ranked_counts.category_id = categories.id
        SQL
        .select("categories.*, ranked_counts.ranked_count")

      order_by(scope, sort, "categories.name")
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

    def self.order_by(scope, sort, name_column)
      return scope.order(name_column) if normalized_sort(sort) == "name"

      scope.order("ranked_counts.ranked_count DESC", name_column)
    end
    private_class_method :order_by
  end
end
