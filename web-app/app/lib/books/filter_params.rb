module Books
  class FilterParams
    YEAR_FORMAT = /\A-?\d+\z/
    YEAR_RANGE = (-4000..(Date.current.year + 5))
    MAX_CATEGORIES = 6
    MAX_COUNTRIES = 10

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
      year = validated_year(@params[:year])
      categories, redirect = resolve_categories(@params[:category_id])

      Result.new(
        categories: categories,
        countries: resolve(Books::Country.all, @params[:country_id], MAX_COUNTRIES),
        year_start: year || validated_year(@params[:published_start]),
        year_end: year || validated_year(@params[:published_end]),
        redirect: redirect
      )
    end

    private

    def resolve_categories(raw)
      slugs = parse_slugs(raw, MAX_CATEGORIES)
      return [[], false] if slugs.empty?

      active = Books::Category.active.where(slug: slugs).index_by(&:slug)
      missing = slugs - active.keys
      return [active.values.sort_by(&:slug), false] if missing.empty?

      replacements = missing.map { |slug| canonical_for(slug) || raise(ActiveRecord::RecordNotFound) }
      [(active.values + replacements).uniq.sort_by(&:slug), true]
    end

    # A merged category's own slug, or a slug the category had before a rename
    # (friendly_id history), resolved to the category a reader should land on.
    def canonical_for(slug)
      merged = Books::Category.merged.find_by(slug: slug)
      return merged.canonical if merged

      historical = FriendlyId::Slug
        .where(sluggable_type: "Category", scope: "type:Books::Category", slug: slug)
        .order(id: :desc).first
      return nil if historical.nil?

      Books::Category.find_by(id: historical.sluggable_id)&.canonical
    end

    def parse_slugs(raw, max)
      slugs = raw.to_s.split(",").map(&:strip).reject(&:blank?).uniq
      raise ActiveRecord::RecordNotFound if slugs.size > max

      slugs
    end

    def resolve(scope, raw, max)
      slugs = parse_slugs(raw, max)
      return [] if slugs.empty?

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
