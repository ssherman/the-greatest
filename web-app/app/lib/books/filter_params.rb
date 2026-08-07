module Books
  class FilterParams
    YEAR_FORMAT = /\A-?\d+\z/
    YEAR_RANGE = (-4000..(Date.current.year + 5))
    MAX_CATEGORIES = 6
    MAX_COUNTRIES = 10

    Result = Struct.new(:categories, :countries, :year_start, :year_end, keyword_init: true)

    def self.call(params)
      new(params).call
    end

    def initialize(params)
      @params = params
    end

    def call
      year = validated_year(@params[:year])

      Result.new(
        categories: resolve(Books::Category.active, @params[:category_id], MAX_CATEGORIES),
        countries: resolve(Books::Country.all, @params[:country_id], MAX_COUNTRIES),
        year_start: year || validated_year(@params[:published_start]),
        year_end: year || validated_year(@params[:published_end])
      )
    end

    private

    def resolve(scope, raw, max)
      slugs = raw.to_s.split(",").map(&:strip).reject(&:blank?).uniq
      return [] if slugs.empty?
      raise ActiveRecord::RecordNotFound if slugs.size > max

      records = scope.where(slug: slugs).sort_by(&:slug)
      raise ActiveRecord::RecordNotFound if records.size != slugs.size

      records
    end

    def validated_year(raw)
      return nil if raw.blank?

      value = raw.to_s
      raise ActiveRecord::RecordNotFound unless value.match?(YEAR_FORMAT)

      year = value.to_i
      raise ActiveRecord::RecordNotFound unless YEAR_RANGE.cover?(year)

      year.to_s
    end
  end
end
