# frozen_string_literal: true

module Api
  # Maps the API's filter parameters onto the arguments of Books::RankedBooksQuery.
  # The website's rules live in Books::FilterParams; this adds the ones only an API
  # needs (a blank value is an error, not "unfiltered"; `collection` is a parameter,
  # not a route) and re-raises FilterParams' two RecordNotFound subclasses as the
  # API's own errors, so neither reaches ErrorRendering's generic 404.
  #
  # `applied` echoes back only the filters that were sent, in canonical form, so a
  # client (and links.next) can see what the server understood.
  class RankedBookFilters
    PARAMS = %i[category_id country_id year published_start published_end collection].freeze
    RANGE_PARAMS = %i[published_start published_end].freeze

    Result = Struct.new(:categories, :countries, :year_start, :year_end, :collection, :applied, keyword_init: true)

    def self.call(params, path_category: nil)
      new(params, path_category: path_category).call
    end

    def initialize(params, path_category: nil)
      @params = params
      @path_category = path_category
    end

    def call
      reject_blank_values
      reject_year_with_range
      collection = resolve_collection
      reject_country_with_collection

      filters = resolve_filters
      Result.new(
        categories: filters.categories,
        countries: filters.countries,
        year_start: filters.year_start,
        year_end: filters.year_end,
        collection: collection,
        applied: applied(filters, collection)
      )
    end

    private

    def reject_blank_values
      blank = PARAMS.find { |name| @params.key?(name) && @params[name].blank? }
      raise Api::Page::InvalidParameter, "#{blank} must not be blank" if blank
    end

    def reject_year_with_range
      return unless sent?(:year) && RANGE_PARAMS.any? { |name| sent?(name) }

      raise Api::Page::InvalidParameter, "year cannot be combined with published_start or published_end"
    end

    def resolve_collection
      return nil unless sent?(:collection)

      ::Collections::Registry.find(:books, @params[:collection]) ||
        raise(Api::Page::InvalidParameter, "collection must be one of: #{::Collections::Registry.slugs(:books).join(", ")}")
    end

    def reject_country_with_collection
      return unless sent?(:country_id) && sent?(:collection)

      raise Api::Page::InvalidParameter, "country_id cannot be combined with collection"
    end

    def resolve_filters
      ::Books::FilterParams.call(
        category_id: category_id_with_path_category,
        country_id: @params[:country_id],
        year: @params[:year],
        published_start: @params[:published_start],
        published_end: @params[:published_end]
      )
    rescue ::Books::FilterParams::InvalidFilter => error
      raise Api::Page::InvalidParameter, error.message
    rescue ::Books::FilterParams::UnknownFilter => error
      raise Api::UnknownFilter.new(error.param, error.slug)
    end

    # The path category joins the sent slugs before FilterParams counts them, so
    # the limit of 6 applies to the union.
    def category_id_with_path_category
      return @params[:category_id] if @path_category.nil?

      [@path_category.slug, *@params[:category_id].to_s.split(",")].join(",")
    end

    def applied(filters, collection)
      applied = {}

      slugs = filters.categories.map(&:slug) - [@path_category&.slug]
      applied[:category_id] = slugs.sort.join(",") if sent?(:category_id) && slugs.any?
      applied[:country_id] = filters.countries.map(&:slug).sort.join(",") if sent?(:country_id)
      if sent?(:year)
        applied[:year] = filters.year_start.to_i
      else
        applied[:published_start] = filters.year_start.to_i if sent?(:published_start)
        applied[:published_end] = filters.year_end.to_i if sent?(:published_end)
      end
      applied[:collection] = collection.slug if collection
      applied
    end

    def sent?(name) = @params.key?(name)
  end
end
