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

  def self.call(query, scope:, types: [], limit: DEFAULT_LIMIT, min_items: 0, min_items_types: [])
    new(query, scope: scope, types: types, limit: limit, min_items: min_items, min_items_types: min_items_types).call
  end

  def initialize(query, scope:, types: [], limit: DEFAULT_LIMIT, min_items: 0, min_items_types: [])
    @query = query.to_s.strip
    @scope = scope
    @types = Array(types)
    @limit = limit
    @min_items = min_items.to_i
    @min_items_types = Array(min_items_types).map(&:to_s)
  end

  def call
    return [] if @query.blank?

    relation = @scope.active.where(name_or_alias_sql, pattern: "%#{@scope.sanitize_sql_like(@query)}%")
    relation = relation.where(category_type: @types) if @types.any?
    relation = apply_minimum(relation)

    relation.order(item_count: :desc, name: :asc).limit(@limit).to_a
  end

  private

  # Old names and spellings live in alternative_names, so "Calcutta" finds Kolkata.
  def name_or_alias_sql
    "categories.name ILIKE :pattern OR EXISTS (SELECT 1 FROM unnest(categories.alternative_names) AS alt WHERE alt ILIKE :pattern)"
  end

  def apply_minimum(relation)
    return relation if @min_items <= 0 || @min_items_types.empty?

    type_values = @min_items_types.map { |type| ::Category.category_types.fetch(type) }
    relation.where("categories.category_type NOT IN (:types) OR categories.item_count >= :min", types: type_values, min: @min_items)
  end
end
