module Books
  class FilterParams
    YEAR_FORMAT = /\A-?\d+\z/
    YEAR_RANGE = (-4000..(Date.current.year + 5))
    MAX_CATEGORIES = 6
    MAX_COUNTRIES = 10

    # Input that cannot be a filter at all: too many slugs, or a year that is not an
    # integer in range. The website 404s on it (both classes are RecordNotFound); the
    # API answers 400.
    class InvalidFilter < ActiveRecord::RecordNotFound
      attr_reader :param

      def initialize(param, detail)
        @param = param
        super("Invalid #{param}: #{detail}")
      end
    end

    # A well-formed slug that names nothing. The website 404s; the API answers 404.
    class UnknownFilter < ActiveRecord::RecordNotFound
      attr_reader :param, :slug

      def initialize(param, slug)
        @param = param
        @slug = slug
        super("Unknown #{param}: #{slug}")
      end
    end

    Result = Struct.new(:categories, :countries, :year_start, :year_end, :redirect, keyword_init: true) do
      # True when a category slug resolved through a merge or a pre-rename slug;
      # the page should 301 to the canonical URL built from `categories`.
      def redirect? = redirect == true
    end

    def self.call(params)
      new(params).call
    end

    def initialize(params)
      @params = params
    end

    def call
      year = validated_year("year", @params[:year])
      categories, redirect = resolve_categories(@params[:category_id])

      Result.new(
        categories: categories,
        countries: resolve("country_id", Books::Country.all, @params[:country_id], MAX_COUNTRIES),
        year_start: year || validated_year("published_start", @params[:published_start]),
        year_end: year || validated_year("published_end", @params[:published_end]),
        redirect: redirect
      )
    end

    private

    def resolve_categories(raw)
      slugs = parse_slugs("category_id", raw, MAX_CATEGORIES)
      return [[], false] if slugs.empty?

      active = Books::Category.active.where(slug: slugs).index_by(&:slug)
      missing = slugs - active.keys
      return [active.values.sort_by(&:slug), false] if missing.empty?

      replacements = missing.map { |slug| Books::CategorySlugResolver.call(slug) || raise(UnknownFilter.new("category_id", slug)) }
      [(active.values + replacements).uniq.sort_by(&:slug), true]
    end

    def parse_slugs(param, raw, max)
      slugs = raw.to_s.split(",").map(&:strip).reject(&:blank?).uniq
      raise InvalidFilter.new(param, "at most #{max} values allowed") if slugs.size > max

      slugs
    end

    def resolve(param, scope, raw, max)
      slugs = parse_slugs(param, raw, max)
      return [] if slugs.empty?

      records = scope.where(slug: slugs).sort_by(&:slug)
      raise UnknownFilter.new(param, (slugs - records.map(&:slug)).first) if records.size != slugs.size

      records
    end

    def validated_year(param, raw)
      return nil if raw.blank?

      value = raw.to_s
      raise InvalidFilter.new(param, "must be an integer year") unless value.match?(YEAR_FORMAT)

      year = value.to_i
      raise InvalidFilter.new(param, "must be between #{YEAR_RANGE.begin} and #{YEAR_RANGE.end}") unless YEAR_RANGE.cover?(year)

      year.to_s
    end
  end
end
