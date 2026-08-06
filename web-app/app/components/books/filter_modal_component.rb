module Books
  class FilterModalComponent < ViewComponent::Base
    AXES = [
      {axis: "category", label: "Category", hint: "Genre, subject, or setting"},
      {axis: "country", label: "Origin", hint: "The book's national tradition, not the author's birthplace"},
      {axis: "year", label: "Published", hint: nil}
    ].freeze

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

    def max_categories
      Books::FilterParams::MAX_CATEGORIES
    end

    def max_countries
      Books::FilterParams::MAX_COUNTRIES
    end

    def rc_param
      ranking_configuration&.primary? ? nil : ranking_configuration&.id
    end

    def pane_src(axis)
      path = (axis == "category") ? helpers.books_filters_categories_path : helpers.books_filters_countries_path

      "#{path}?#{filter_query}"
    end

    def filter_query
      {
        category_slugs: categories.map(&:slug),
        country_slugs: countries.map(&:slug),
        year_start: year_start,
        year_end: year_end,
        ranking_configuration_id: rc_param
      }.compact_blank.to_query
    end

    def summary_for(axis)
      case axis
      when "category" then names_or_any(categories)
      when "country" then names_or_any(countries)
      else year_summary
      end
    end

    def names_or_any(records)
      records.any? ? records.map(&:name).join(", ") : "Any"
    end

    def year_summary
      return "#{year_start}–#{year_end}" if year_start.present? && year_end.present? && year_start != year_end
      return year_start if year_start.present? && year_start == year_end
      return "Since #{year_start}" if year_start.present?
      return "To #{year_end}" if year_end.present?

      "Any"
    end

    def clear_path
      Books::FilterPath.call(ranking_configuration: ranking_configuration)
    end
  end
end
