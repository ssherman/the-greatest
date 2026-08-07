module Books
  class FilterPath
    def self.call(**options)
      new(**options).call
    end

    def self.indexable?(categories: [], countries: [])
      Array(categories).size <= 1 && Array(countries).size <= 1
    end

    def initialize(categories: [], countries: [], year_start: nil, year_end: nil, page: nil, ranking_configuration: nil)
      @categories = categories || []
      @countries = countries || []
      @year_start = year_start.presence
      @year_end = year_end.presence
      @page = page.to_i
      @ranking_configuration = ranking_configuration
    end

    def call
      return unfiltered_path if @categories.empty? && @countries.empty? && @year_start.nil? && @year_end.nil?

      "#{prefix}#{base_segment}#{country_segment}#{date_segment}#{page_segment}"
    end

    private

    def unfiltered_path
      return "#{prefix}/page/#{@page}" if @page > 1

      prefix.presence || "/"
    end

    def prefix
      return "" if @ranking_configuration.nil? || @ranking_configuration.primary?

      "/rc/#{@ranking_configuration.id}"
    end

    def base_segment
      return "/the-greatest-books" if @categories.empty?

      "/the-greatest/#{slugs(@categories)}/books"
    end

    def country_segment
      return "" if @countries.empty?

      "/written-by/#{slugs(@countries)}/authors"
    end

    def date_segment
      return "/of/#{@year_start}" if @year_start && @year_start == @year_end
      return "/from/#{@year_start}/to/#{@year_end}" if @year_start && @year_end
      return "/since/#{@year_start}" if @year_start
      return "/to/#{@year_end}" if @year_end

      ""
    end

    def page_segment
      (@page > 1) ? "/page/#{@page}" : ""
    end

    def slugs(records)
      records.map(&:slug).sort.join(",")
    end
  end
end
