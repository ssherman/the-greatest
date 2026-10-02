class ListsQuery
  SORTS = %w[weight newest].freeze

  def self.list_type
    raise NotImplementedError, "#{name} must define .list_type"
  end

  # The "an active list of this medium" predicate, for a relation that has
  # joined lists. Anything that must agree with this query's row count -- the
  # API's list_count on a configuration, the lists a book is on -- filters on
  # this rather than restating it.
  def self.active_list_conditions
    {lists: {type: list_type, status: ::List.statuses[:active]}}
  end

  def self.normalize_sort(value)
    SORTS.include?(value.to_s) ? value.to_s : "weight"
  end

  def self.call(ranking_configuration:, sort: "weight", query: nil)
    new(ranking_configuration: ranking_configuration, sort: sort, query: query).call
  end

  def initialize(ranking_configuration:, sort:, query:)
    @ranking_configuration = ranking_configuration
    @sort = self.class.normalize_sort(sort)
    @query = query
  end

  def call
    scope = @ranking_configuration.ranked_lists
      .joins(:list)
      .where(self.class.active_list_conditions)
      .includes(:list)

    scope = scope.where(list_id: ::List.search_text(@query).select(:id)) if @query.present?

    scope.order(Arel.sql(order_clause))
  end

  private

  # NULLS LAST on both: a list the admin has just attached has no weight until
  # the next refresh, and Postgres would otherwise put it first on a DESC sort.
  def order_clause
    if @sort == "newest"
      "lists.activated_at DESC NULLS LAST, lists.id ASC"
    else
      "ranked_lists.weight DESC NULLS LAST, lists.id ASC"
    end
  end
end
