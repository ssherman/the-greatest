module Books
  # Facet counts for the filter panel, one category type (or the countries) per
  # call. The two axes are asymmetric on purpose: categories AND, so their facet
  # keeps the category filter applied and reports the intersection you would
  # actually get by drilling down; countries OR, so their facet drops the country
  # filter and reports alternatives. Applied selections stay in the list -- the
  # panel renders them as ticked checkboxes -- so a selection that matches no
  # ranked book is appended with count 0 rather than silently vanishing.
  class FilterFacetsQuery
    TYPES = %w[genre audience subject location].freeze

    def self.categories(type:, ranking_configuration:, categories: [], countries: [], year_start: nil, year_end: nil, collection: nil, limit: nil)
      raise ArgumentError, "unknown category type: #{type.inspect}" unless TYPES.include?(type.to_s)

      build(ranking_configuration, categories, countries, year_start, year_end, collection)
        .category_facet(type.to_s, limit)
    end

    def self.countries(ranking_configuration:, categories: [], countries: [], year_start: nil, year_end: nil, collection: nil)
      build(ranking_configuration, categories, countries, year_start, year_end, collection).country_facet
    end

    def self.build(ranking_configuration, categories, countries, year_start, year_end, collection)
      new(
        ranking_configuration: ranking_configuration,
        categories: Array(categories),
        countries: Array(countries),
        year_start: year_start,
        year_end: year_end,
        collection: collection
      )
    end
    private_class_method :build

    def initialize(ranking_configuration:, categories:, countries:, year_start:, year_end:, collection: nil)
      @ranking_configuration = ranking_configuration
      @categories = categories
      @countries = countries
      @year_start = year_start
      @year_end = year_end
      @collection = collection
    end

    def category_facet(type, limit)
      scope = CategoryItem
        .where(item_type: "Books::Book", item_id: book_ids(countries: @countries, categories: @categories))
        .joins(:category)
        .where(categories: {deleted: false, category_type: Category.category_types.fetch(type), type: "Books::Category"})
        .group(:category_id)

      counts = scope.order(count_all: :desc, category_id: :asc).limit(limit).count
      rows = rows_for(Books::Category.where(id: counts.keys), counts)

      # An applied category carries every book in the result, so it ties for the
      # top count and can fall past the limit on the id tiebreak. Its real count
      # is appended, not zero; zero is only for categories with genuinely no books.
      missing = @categories.select { |category| category.category_type == type && counts.keys.exclude?(category.id) }
      if missing.any?
        extra = scope.where(category_id: missing.map(&:id)).count
        rows += missing.map { |category| {record: category, count: extra.fetch(category.id, 0)} }
      end
      rows
    end

    def country_facet
      counts = Books::BookCountry
        .where(book_id: book_ids(countries: [], categories: @categories))
        .where(country_id: Books::Country.filterable.select(:id))
        .group(:country_id)
        .order(count_all: :desc, country_id: :asc)
        .count

      rows = rows_for(Books::Country.where(id: counts.keys), counts)
      listed = rows.map { |row| row[:record].id }
      rows + @countries.reject { |country| listed.include?(country.id) }.map { |country| {record: country, count: 0} }
    end

    private

    # RankedBooksQuery returns a relation carrying includes(...) and order(:rank)
    # for rendering. Both are wrong inside a subquery -- eager-load joins change
    # the shape, and ordering an IN (...) subquery is meaningless -- so strip them.
    def book_ids(countries:, categories:)
      RankedBooksQuery.call(
        ranking_configuration: @ranking_configuration,
        categories: categories,
        countries: countries,
        year_start: @year_start,
        year_end: @year_end,
        collection: @collection
      ).except(:includes).reorder(nil).reselect(:item_id)
    end

    def rows_for(scope, counts)
      by_id = scope.index_by(&:id)
      counts.map { |id, count| {record: by_id[id], count: count} }.reject { |row| row[:record].nil? }
    end
  end
end
