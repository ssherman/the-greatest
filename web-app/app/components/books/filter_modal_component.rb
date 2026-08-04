module Books
  class FilterModalComponent < ViewComponent::Base
    def initialize(categories: [], countries: [], year_start: nil, year_end: nil, ranking_configuration: nil)
      @categories = categories || []
      @countries = countries || []
      @year_start = year_start
      @year_end = year_end
      @ranking_configuration = ranking_configuration
    end

    private

    attr_reader :categories, :countries, :year_start, :year_end, :ranking_configuration

    def modal_id
      Books::FilterBarComponent::MODAL_ID
    end

    def options_path
      helpers.books_filters_options_path(
        category_slugs: categories.map(&:slug),
        country_slugs: countries.map(&:slug),
        year_start: year_start,
        year_end: year_end,
        ranking_configuration_id: (ranking_configuration&.primary? ? nil : ranking_configuration&.id)
      )
    end
  end
end
