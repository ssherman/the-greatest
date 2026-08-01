module Books
  class ListsQuery
    SORTS = %w[weight newest].freeze

    def self.call(ranking_configuration:, sort: "weight", query: nil)
      new(ranking_configuration: ranking_configuration, sort: sort, query: query).call
    end

    def initialize(ranking_configuration:, sort:, query:)
      @ranking_configuration = ranking_configuration
      @sort = SORTS.include?(sort.to_s) ? sort.to_s : "weight"
      @query = query
    end

    def call
      scope = @ranking_configuration.ranked_lists
        .joins(:list)
        .where(lists: {type: "Books::List", status: ::List.statuses[:active]})
        .includes(:list)

      scope = scope.where(list_id: ::List.search_text(@query).select(:id)) if @query.present?

      scope.order(Arel.sql(order_clause))
    end

    private

    def order_clause
      if @sort == "newest"
        "lists.activated_at DESC NULLS LAST, lists.id ASC"
      else
        "ranked_lists.weight DESC, lists.id ASC"
      end
    end
  end
end
