module Books
  class CountrySearchQuery
    DEFAULT_LIMIT = 10

    def self.call(query, limit: DEFAULT_LIMIT)
      new(query, limit: limit).call
    end

    def initialize(query, limit:)
      @query = query.to_s.strip
      @limit = limit
    end

    def call
      return [] if @query.blank?

      Books::Country
        .filterable
        .search_by_name(@query)
        .order(book_count: :desc, name: :asc)
        .limit(@limit)
        .to_a
    end
  end
end
