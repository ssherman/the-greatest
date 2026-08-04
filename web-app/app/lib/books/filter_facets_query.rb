module Books
  # Facet counts for the filter modal. The two axes are asymmetric on purpose:
  # genres AND, so their facet keeps the category filter applied and reports the
  # intersection you would actually get by drilling down; countries OR, so their
  # facet drops the country filter and reports alternatives. Each axis omits
  # what is already selected. Mirrors the legacy site's behaviour.
  class FilterFacetsQuery
    DEFAULT_LIMIT = 36

    Result = Struct.new(:genres, :countries, keyword_init: true)

    def self.call(ranking_configuration:, categories: [], countries: [], year_start: nil, year_end: nil, limit: DEFAULT_LIMIT)
      new(
        ranking_configuration: ranking_configuration,
        categories: Array(categories),
        countries: Array(countries),
        year_start: year_start,
        year_end: year_end,
        limit: limit
      ).call
    end

    def initialize(ranking_configuration:, categories:, countries:, year_start:, year_end:, limit:)
      @ranking_configuration = ranking_configuration
      @categories = categories
      @countries = countries
      @year_start = year_start
      @year_end = year_end
      @limit = limit
    end

    def call
      Result.new(genres: genre_facet, countries: country_facet)
    end

    private

    def genre_facet
      counts = CategoryItem
        .where(item_type: "Books::Book", item_id: book_ids(countries: @countries, categories: @categories))
        .joins(:category)
        .where(categories: {deleted: false, category_type: Category.category_types[:genre], type: "Books::Category"})
        .where.not(category_id: @categories.map(&:id))
        .group(:category_id)
        .order(count_all: :desc, category_id: :asc)
        .limit(@limit)
        .count

      rows_for(Books::Category.where(id: counts.keys), counts)
    end

    def country_facet
      counts = Books::BookCountry
        .where(book_id: book_ids(countries: [], categories: @categories))
        .where.not(country_id: @countries.map(&:id))
        .where(country_id: Books::Country.filterable.select(:id))
        .group(:country_id)
        .order(count_all: :desc, country_id: :asc)
        .limit(@limit)
        .count

      rows_for(Books::Country.where(id: counts.keys), counts)
    end

    # RankedBooksQuery returns a relation carrying includes(...) and order(:rank)
    # for rendering. Both are wrong inside a subquery -- eager-load joins change
    # the shape, and ordering an IN (...) subquery is meaningless -- so strip them.
    def book_ids(countries:, categories:)
      RankedBooksQuery.call(
        ranking_configuration: @ranking_configuration,
        categories: categories,
        countries: countries,
        year_start: @year_start,
        year_end: @year_end
      ).except(:includes).reorder(nil).reselect(:item_id)
    end

    def rows_for(scope, counts)
      by_id = scope.index_by(&:id)
      counts.map { |id, count| {record: by_id[id], count: count} }.reject { |row| row[:record].nil? }
    end
  end
end
