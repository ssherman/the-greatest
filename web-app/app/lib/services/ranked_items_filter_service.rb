module Services
  class RankedItemsFilterService
    def initialize(base_query, table_name:)
      @base_query = base_query
      @table_name = table_name
    end

    def apply_year_filter(year_filter)
      return @base_query if year_filter.nil?

      if year_filter.start_year.nil?
        # Open start (through): beginning to end_year
        @base_query.where("#{@table_name}.release_year <= ?", year_filter.end_year)
      elsif year_filter.end_year.nil?
        # Open end (since): start_year to present
        @base_query.where("#{@table_name}.release_year >= ?", year_filter.start_year)
      else
        # Closed range
        @base_query.where("#{@table_name}.release_year BETWEEN ? AND ?", year_filter.start_year, year_filter.end_year)
      end
    end
  end
end
