module Books
  class FilterModalComponent < ViewComponent::Base
    ROWS = [
      {key: "genre", label: "Genre", plural: "genres"},
      {key: "year", label: "Published", plural: "years"},
      {key: "audience", label: "Audience", plural: "audiences"},
      {key: "country", label: "Origin", plural: "origins", hint: "The book's national tradition, not the author's birthplace"},
      {key: "subject", label: "Subject", plural: "subjects"},
      {key: "location", label: "Setting", plural: "settings", hint: "Where the book is set or the place it covers, not where it comes from"}
    ].freeze

    ERAS = [
      {label: "Since 2000", start: 2000, end: nil},
      {label: "1950–1999", start: 1950, end: 1999},
      {label: "1900–1949", start: 1900, end: 1949},
      {label: "1800s", start: 1800, end: 1899},
      {label: "Before 1800", start: nil, end: 1799}
    ].freeze

    RECENT_YEAR_COUNT = 5

    # Genre and Origin lists ship whole and filter in the browser; Subject and
    # Setting are too long for that, so their search box asks the server.
    SERVER_SEARCH_TYPES = %w[subject location].freeze

    def initialize(categories: [], countries: [], year_start: nil, year_end: nil, ranking_configuration: nil, collection: nil, total_count: 0)
      @categories = categories || []
      @countries = countries || []
      @year_start = year_start
      @year_end = year_end
      @ranking_configuration = ranking_configuration
      @collection = collection
      @total_count = total_count.to_i
    end

    private

    attr_reader :categories, :countries, :year_start, :year_end, :ranking_configuration, :collection, :total_count

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

    # Origin is the collection's own axis -- offering it would let a reader pick a
    # country the collection cannot contain and land on an empty page. Legacy had no
    # such URL either.
    def rows
      collection ? ROWS.reject { |row| row[:key] == "country" } : ROWS
    end

    def type_rows
      rows.reject { |row| row[:key] == "year" }
    end

    def searchable?(key)
      key != "audience"
    end

    def search_mode(key)
      SERVER_SEARCH_TYPES.include?(key) ? "search" : "filter"
    end

    def chips?(key)
      SERVER_SEARCH_TYPES.include?(key)
    end

    def pane_src(key)
      if key == "country"
        "#{helpers.books_filters_countries_path}?#{filter_params.to_query}"
      else
        "#{helpers.books_filters_categories_path}?#{{type: key}.merge(filter_params).to_query}"
      end
    end

    def filter_params
      {
        category_slugs: categories.map(&:slug),
        country_slugs: countries.map(&:slug),
        year_start: year_start,
        year_end: year_end,
        ranking_configuration_id: rc_param,
        collection: collection&.slug
      }.compact_blank
    end

    def summary_for(key)
      case key
      when "year" then year_summary
      when "country" then names_or_any(countries)
      else names_or_any(categories.select { |category| category.category_type.to_s == key })
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

    def recent_years
      (1..RECENT_YEAR_COUNT).map { |offset| Date.current.year - offset }
    end

    def pressed?(start, finish)
      [year_start.to_s, year_end.to_s] == [start.to_s, finish.to_s]
    end

    def show_label(count)
      "Show #{helpers.number_with_delimiter(count)} #{(count == 1) ? "book" : "books"}"
    end
  end
end
