module Books
  # Builds the browse paths: /categories[/settings|/subjects][/sorted-by/:sort]
  # [/page/:n] and /countries[/sorted-by/:sort][/page/:n]. Mirrors
  # Books::FilterPath: the parameterised routes are unnamed, so this PORO is the
  # only place the grammar is spelled out. Values normalize through BrowseQuery,
  # so an unknown filter or sort collapses to the default instead of reaching a
  # path.
  #
  # The old /genres/filtered-by/:filter grammar is not built any more; it only
  # survives as redirect input, which from_legacy_genres turns into the new path.
  class BrowsePath
    BASES = {categories: "/categories", countries: "/countries"}.freeze

    # The genre type is the page's default view, so it has no segment.
    TYPE_SEGMENTS = {"location" => "settings", "subject" => "subjects"}.freeze

    def self.call(**options)
      new(**options).call
    end

    # The /genres redirect route hands over its path params (symbol keys) and the
    # request's query params (string keys). Path params win, because a request
    # such as /genres/filtered-by/subject?filter=location is about the subject
    # page.
    def self.from_legacy_genres(path_params:, query_params:)
      merged = query_params.to_h.slice("filter", "sort", "page")
        .merge(path_params.to_h.stringify_keys.slice("filter", "sort", "page"))

      call(axis: :categories, type: merged["filter"], sort: merged["sort"], page: merged["page"])
    end

    def initialize(axis:, type: nil, sort: nil, page: nil)
      @axis = axis.to_sym
      @base = BASES.fetch(@axis)
      @type = Books::BrowseQuery.normalized_type(type)
      @sort = Books::BrowseQuery.normalized_sort(sort)
      @page = page.to_s.to_i
    end

    def call
      "#{@base}#{filter_segment}#{sort_segment}#{page_segment}"
    end

    private

    def filter_segment
      return "" if @axis == :countries
      return "" if @type == Books::BrowseQuery::TYPES.first

      "/#{TYPE_SEGMENTS.fetch(@type)}"
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
