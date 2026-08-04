module Books
  class FilterFacetsComponent < ViewComponent::Base
    def initialize(facets:, categories: [], countries: [], year_start: nil, year_end: nil, ranking_configuration: nil)
      @facets = facets
      @categories = categories || []
      @countries = countries || []
      @year_start = year_start
      @year_end = year_end
      @ranking_configuration = ranking_configuration
    end

    private

    attr_reader :facets, :categories, :countries, :year_start, :year_end, :ranking_configuration

    def selected_genres
      categories.select { |category| category.category_type.to_s == "genre" }
    end

    # A location/subject category can arrive from a book page's link. The modal
    # offers genres only, so those must ride along hidden or Apply would drop them.
    def preserved_categories
      categories - selected_genres
    end

    def genre_options
      selected_genres.map { |category| {record: category, count: nil, checked: true} } +
        facets.genres.map { |row| {record: row[:record], count: row[:count], checked: false} }
    end

    def country_options
      countries.map { |country| {record: country, count: nil, checked: true} } +
        facets.countries.map { |row| {record: row[:record], count: row[:count], checked: false} }
    end

    def clear_path
      Books::FilterPath.call(ranking_configuration: ranking_configuration)
    end
  end
end
