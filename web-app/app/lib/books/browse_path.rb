module Books
  # Builds the legacy browse grammar (/genres/filtered-by/:filter/sorted-by/:sort).
  # Mirrors Books::FilterPath: the routes are unnamed, so this PORO is the only
  # place the grammar is spelled out. Values normalize through BrowseQuery, so an
  # unknown filter or sort collapses to the default instead of reaching a path.
  class BrowsePath
    BASES = {genres: "/genres", countries: "/countries"}.freeze

    def self.call(**options)
      new(**options).call
    end

    def initialize(axis:, type: nil, sort: nil, page: nil)
      @axis = axis.to_sym
      @base = BASES.fetch(@axis)
      @type = Books::BrowseQuery.normalized_type(type)
      @sort = Books::BrowseQuery.normalized_sort(sort)
      @page = page.to_i
    end

    def call
      "#{@base}#{filter_segment}#{sort_segment}#{page_segment}"
    end

    private

    def filter_segment
      return "" if @axis == :countries
      return "" if @type == Books::BrowseQuery::TYPES.first

      "/filtered-by/#{@type}"
    end

    def sort_segment
      return "" if @sort == Books::BrowseQuery::SORTS.first

      "/sorted-by/#{@sort}"
    end

    def page_segment
      (@page > 1) ? "/page/#{@page}" : ""
    end
  end
end
