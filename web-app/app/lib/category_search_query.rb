# frozen_string_literal: true

# Searches one domain's categories by name.
#
# Replaces two independent implementations that had drifted apart on ordering,
# limit, blank-query handling, and whether a result says what type it is:
# Admin::CategoriesBaseController#search (cross-domain, labelled, admin-only)
# and Books::CategorySearchQuery (public, books-only, unlabelled).
#
# Takes `scope:` rather than a domain symbol because every caller already holds
# its class -- an admin controller has model_class -- and passing it keeps this
# object from growing a domain registry.
#
# `types:` defaults to unscoped, and that default is load-bearing. Both callers
# need every type: the admin add-category modal because a book is legitimately
# tagged with a subject or a setting, and the books filter modal because its
# Category axis is DEFINED as all three (see the spec's landmines).
class CategorySearchQuery
  DEFAULT_LIMIT = 10

  # Old names and spellings live in alternative_names, so "Calcutta" finds Kolkata.
  # Public so a caller that builds its own relation (Books::BrowseQuery.search)
  # matches names exactly the way this class does. Binds :pattern.
  NAME_OR_ALIAS_SQL = "categories.name ILIKE :pattern OR EXISTS (SELECT 1 FROM unnest(categories.alternative_names) AS alt WHERE alt ILIKE :pattern)"

  def self.call(query, scope:, types: [], limit: DEFAULT_LIMIT, min_items: 0, min_items_types: [], min_items_item_type: nil)
    new(query, scope: scope, types: types, limit: limit, min_items: min_items, min_items_types: min_items_types, min_items_item_type: min_items_item_type).call
  end

  def initialize(query, scope:, types: [], limit: DEFAULT_LIMIT, min_items: 0, min_items_types: [], min_items_item_type: nil)
    @query = query.to_s.strip
    @scope = scope
    @types = Array(types)
    @limit = limit
    @min_items = min_items.to_i
    @min_items_types = Array(min_items_types).map(&:to_s)
    @min_items_item_type = min_items_item_type
  end

  def call
    return [] if @query.blank?

    relation = @scope.active.where(NAME_OR_ALIAS_SQL, pattern: "%#{@scope.sanitize_sql_like(@query)}%")
    relation = relation.where(category_type: @types) if @types.any?
    relation = apply_minimum(relation)

    relation.order(item_count: :desc, name: :asc).limit(@limit).to_a
  end

  private

  def apply_minimum(relation)
    return relation if @min_items <= 0 || @min_items_types.empty?

    type_values = @min_items_types.map { |type| ::Category.category_types.fetch(type) }
    # item_count counts every polymorphic link (authors included); a caller that
    # cares about one kind of item names it and gets a correlated count instead.
    count_sql = if @min_items_item_type
      # item_count is a cheap necessary condition; the capped count then checks
      # only that many book links exist, without counting a whole category.
      "categories.item_count >= :min AND (SELECT COUNT(*) FROM (SELECT 1 FROM category_items ci WHERE ci.category_id = categories.id AND ci.item_type = :item_type LIMIT :min) capped) >= :min"
    else
      "categories.item_count >= :min"
    end
    relation.where("categories.category_type NOT IN (:types) OR (#{count_sql})", types: type_values, min: @min_items, item_type: @min_items_item_type)
  end
end
