module Books
  class FilterBarComponent < ViewComponent::Base
    MODAL_ID = "books_filter_modal"

    def initialize(categories: [], countries: [], year_start: nil, year_end: nil, ranking_configuration: nil, collection: nil)
      @categories = categories || []
      @countries = countries || []
      @year_start = year_start
      @year_end = year_end
      @ranking_configuration = ranking_configuration
      @collection = collection
    end

    private

    attr_reader :categories, :countries, :year_start, :year_end, :ranking_configuration, :collection

    def modal_id
      MODAL_ID
    end

    def chips
      category_chips + country_chips + date_chips
    end

    def category_chips
      categories.map do |category|
        {label: category.name, path: path_without(categories: categories - [category])}
      end
    end

    def country_chips
      countries.map do |country|
        {label: country.name, path: path_without(countries: countries - [country])}
      end
    end

    def date_chips
      return [] if year_start.blank? && year_end.blank?

      [{label: date_label, path: path_without(year_start: nil, year_end: nil)}]
    end

    def date_label
      return year_start if year_start.present? && year_start == year_end
      return "#{year_start}–#{year_end}" if year_start.present? && year_end.present?
      return "Since #{year_start}" if year_start.present?

      "To #{year_end}"
    end

    def path_without(categories: self.categories, countries: self.countries, year_start: self.year_start, year_end: self.year_end)
      Books::FilterPath.call(
        categories: categories,
        countries: countries,
        year_start: year_start,
        year_end: year_end,
        ranking_configuration: ranking_configuration,
        collection: collection
      )
    end
  end
end
