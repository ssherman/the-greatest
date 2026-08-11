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

  def self.call(query, scope:, types: [], limit: DEFAULT_LIMIT)
    new(query, scope: scope, types: types, limit: limit).call
  end

  def initialize(query, scope:, types: [], limit: DEFAULT_LIMIT)
    @query = query.to_s.strip
    @scope = scope
    @types = Array(types)
    @limit = limit
  end

  def call
    return [] if @query.blank?

    relation = @scope.active.search_by_name(@query)
    relation = relation.where(category_type: @types) if @types.any?

    relation.order(item_count: :desc, name: :asc).limit(@limit).to_a
  end
end
