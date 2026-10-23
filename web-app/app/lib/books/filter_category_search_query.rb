module Books
  # Search box on the filter panel's Subject and Setting pages: categories of one
  # type whose name or alias matches, kept only if they hold a ranked book under
  # the filters already applied (so a hit never leads to an empty result), and
  # ordered by name-match quality first -- merge junk lives in alternative_names,
  # so an alias-only hit must lose to a real name match -- then by filtered count.
  class FilterCategorySearchQuery
    MAX_LENGTH = 100

    # Subjects and settings are a long tail of one- and two-book categories that
    # exist for similarity, not as filters, so they need the browse minimum of
    # book links, as the pane search before this one did (CategorySearchQuery's
    # min_items with an item type). Genres and audiences are short curated lists.
    MINIMUM_TYPES = %w[subject location].freeze

    # item_count is a cheap necessary condition; the capped count then checks only
    # that that many book links exist, without counting a whole category. Book
    # links, ranked or not: author links do not make a subject findable.
    MINIMUM_SQL = <<~SQL.squish
      categories.item_count >= :min AND (
        SELECT COUNT(*) FROM (
          SELECT 1 FROM category_items ci
          WHERE ci.category_id = categories.id AND ci.item_type = 'Books::Book'
          LIMIT :min
        ) capped
      ) >= :min
    SQL

    def self.call(query:, type:, ranking_configuration:, categories: [], countries: [], year_start: nil, year_end: nil, collection: nil, limit: 10)
      raise ArgumentError, "unknown category type: #{type.inspect}" unless FilterFacetsQuery::TYPES.include?(type.to_s)

      q = query.to_s.strip
      return [] if q.blank? || q.length > MAX_LENGTH

      escaped = Books::Category.sanitize_sql_like(q)

      # The name match runs inside the counting subquery, as in BrowseQuery.search:
      # counting every category's books before matching names is the slow order.
      candidates = Books::Category.active
        .where(category_type: ::Category.category_types.fetch(type.to_s))
        .where(::CategorySearchQuery::NAME_OR_ALIAS_SQL, pattern: "%#{escaped}%")
        .select(:id)
      candidates = apply_minimum(candidates) if MINIMUM_TYPES.include?(type.to_s)

      # RankedBooksQuery carries includes and an order for rendering; both are
      # wrong inside an IN subquery.
      book_ids = RankedBooksQuery.call(
        ranking_configuration: ranking_configuration,
        categories: Array(categories),
        countries: Array(countries),
        year_start: year_start,
        year_end: year_end,
        collection: collection
      ).except(:includes).reorder(nil).reselect(:item_id)

      counts = CategoryItem
        .where(item_type: "Books::Book", item_id: book_ids, category_id: candidates)
        .group(:category_id)
        .select("category_id, COUNT(*) AS filtered_count")

      Books::Category.active
        .joins("INNER JOIN (#{counts.to_sql}) filtered_counts ON filtered_counts.category_id = categories.id")
        .order(Arel.sql(BrowseQuery.name_match_quality_sql(q, escaped)))
        .order("filtered_counts.filtered_count DESC", "categories.name")
        .limit(limit)
        .to_a
    end

    def self.apply_minimum(candidates)
      min = Rails.configuration.x.books.browse_min_category_books.to_i
      return candidates if min <= 0

      candidates.where(MINIMUM_SQL, min: min)
    end
    private_class_method :apply_minimum
  end
end
