module Books
  class FilterParams
    YEAR_FORMAT = /\A-?\d+\z/

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
        categories: resolve(Books::Category.active, @params[:category_id]),
        countries: resolve(Books::Country.all, @params[:country_id]),
        year_start: year || validated_year(@params[:published_start]),
        year_end: year || validated_year(@params[:published_end])
      )
    end

    private

    def resolve(scope, raw)
      slugs = raw.to_s.split(",").map(&:strip).reject(&:blank?).uniq
      return [] if slugs.empty?

      records = scope.where(slug: slugs).sort_by(&:slug)
      raise ActiveRecord::RecordNotFound if records.size != slugs.size

      records
    end

    def validated_year(raw)
      value = raw.presence
      return nil if value.nil?
      raise ActiveRecord::RecordNotFound unless value.match?(YEAR_FORMAT)

      value
    end
  end
end
