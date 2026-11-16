# frozen_string_literal: true

module Api
  # Translates discover_books' query parameters into the criteria hash that
  # Books::SavedSearchCriteria reads, plus the order, the seed and `applied`.
  #
  # Slug resolution is Books::FilterParams' (merged and renamed category slugs
  # included), called once for the includes and once per exclusion list, so an
  # error from an exclusion is re-raised under the API's own parameter name.
  # Every criteria key is a String; `ranked` is absent for "all" and an id array
  # is only written for a parameter that was sent. `applied` echoes only what was
  # sent, in canonical form, and never holds `order` or `seed`: the controller
  # adds those to the links itself.
  class DiscoverBookFilters
    PARAMS = %i[
      category_id category_match exclude_category_id country_id exclude_country_id
      language exclude_language length year published_start published_end
      ranked rank_min rank_max order seed hide_read
    ].freeze
    LIST_PARAMS = %i[category_id exclude_category_id country_id exclude_country_id language exclude_language length].freeze
    RANGE_PARAMS = %i[published_start published_end].freeze
    MAX_LANGUAGES = 10
    MAX_SEED = 2_147_483_647
    RANKED_VALUES = %w[all ranked unranked].freeze
    ORDER_VALUES = %w[rank random].freeze
    MATCH_VALUES = %w[all any].freeze

    Result = Struct.new(:criteria, :order, :seed, :applied, keyword_init: true)

    def self.call(params)
      new(params).call
    end

    def initialize(params)
      @params = params
      @criteria = {}
      @applied = {}
    end

    def call
      reject_malformed_values
      reject_year_with_range

      order = parse_enum(:order, ORDER_VALUES, "rank")
      seed = resolve_seed(order)
      apply_categories_and_countries
      apply_languages
      apply_length
      apply_years
      apply_ranking
      apply_hide_read

      Result.new(criteria: @criteria, order: order.to_sym, seed: seed, applied: @applied)
    end

    private

    # Every value is one scalar. An array or hash is malformed, and a blank value
    # (or a slug list that is only separators) is an error, not "unfiltered".
    def reject_malformed_values
      PARAMS.each do |name|
        next unless sent?(name)

        value = @params[name]
        raise Api::Page::InvalidParameter, "#{name} must be a single value" unless value.is_a?(String) || value.is_a?(Numeric) || [true, false].include?(value)
        raise Api::Page::InvalidParameter, "#{name} must not be blank" if blank_value?(name, value)
      end
    end

    def blank_value?(name, value)
      return value.to_s.split(",").all?(&:blank?) if LIST_PARAMS.include?(name)

      value.to_s.blank?
    end

    def reject_year_with_range
      return unless sent?(:year) && RANGE_PARAMS.any? { |name| sent?(name) }

      raise Api::Page::InvalidParameter, "year cannot be combined with published_start or published_end"
    end

    def parse_enum(name, allowed, default)
      return default unless sent?(name)

      value = @params[name].to_s
      raise Api::Page::InvalidParameter, "#{name} must be one of: #{allowed.join(", ")}" unless allowed.include?(value)

      value
    end

    def resolve_seed(order)
      if order == "random"
        return SecureRandom.random_number(MAX_SEED) + 1 unless sent?(:seed)

        Api::Page.integer(@params[:seed], name: "seed", default: nil, min: 1, max: MAX_SEED)
      else
        raise Api::Page::InvalidParameter, "seed is only valid with order=random" if sent?(:seed)

        nil
      end
    end

    def apply_categories_and_countries
      raise Api::Page::InvalidParameter, "category_match is only valid with category_id" if sent?(:category_match) && !sent?(:category_id)

      match = parse_enum(:category_match, MATCH_VALUES, "all")
      @criteria["genre_match_mode"] = match
      @applied[:category_match] = match if sent?(:category_match)

      categories = filter_result(category_id: @params[:category_id]).categories
      excluded_categories = filter_result({category_id: @params[:exclude_category_id]}, "category_id" => "exclude_category_id").categories
      countries = filter_result(country_id: @params[:country_id]).countries
      excluded_countries = filter_result({country_id: @params[:exclude_country_id]}, "country_id" => "exclude_country_id").countries

      assign_ids(:category_id, :exclude_category_id, "category", categories, excluded_categories)
      assign_ids(:country_id, :exclude_country_id, "country", countries, excluded_countries)
    end

    def filter_result(args, renames = {})
      ::Books::FilterParams.call(args)
    rescue ::Books::FilterParams::InvalidFilter => error
      raise Api::Page::InvalidParameter, error.message.sub(error.param, renames.fetch(error.param, error.param))
    rescue ::Books::FilterParams::UnknownFilter => error
      raise Api::UnknownFilter.new(renames.fetch(error.param, error.param), error.slug)
    end

    def apply_languages
      assign_ids(:language, :exclude_language, "language", resolve_languages(:language), resolve_languages(:exclude_language))
    end

    # Writes `included_<kind>_ids` / `excluded_<kind>_ids` for whichever of the two
    # parameters was sent, after checking the resolved ids do not overlap.
    def assign_ids(include_param, exclude_param, kind, included, excluded)
      overlap = included.find { |record| excluded.map(&:id).include?(record.id) }
      raise Api::Page::InvalidParameter, "#{include_param} and #{exclude_param} both contain #{overlap.slug}" if overlap

      {include_param => [included, "included_#{kind}_ids"], exclude_param => [excluded, "excluded_#{kind}_ids"]}.each do |name, (records, key)|
        next unless sent?(name)

        @criteria[key] = records.map(&:id)
        @applied[name] = records.map(&:slug).sort.join(",")
      end
    end

    def resolve_languages(name)
      return [] unless sent?(name)

      slugs = list_of(name)
      raise Api::Page::InvalidParameter, "#{name} allows at most #{MAX_LANGUAGES} values" if slugs.size > MAX_LANGUAGES

      found = ::Language.where(slug: slugs).sort_by(&:slug)
      missing = slugs - found.map(&:slug)
      raise Api::UnknownFilter.new(name.to_s, missing.first) if missing.any?

      found
    end

    def apply_length
      return unless sent?(:length)

      lengths = ::Books::Book.book_lengths
      names = list_of(:length)
      raise Api::Page::InvalidParameter, "length must be a comma-separated list of: #{lengths.keys.join(", ")}" if (names - lengths.keys).any?

      @criteria["book_length"] = lengths.values_at(*names).sort
      @applied[:length] = lengths.keys.select { |name| names.include?(name) }.join(",")
    end

    def apply_years
      filters = filter_result(year: @params[:year], published_start: @params[:published_start], published_end: @params[:published_end])
      @criteria["first_year_published_gt"] = filters.year_start.to_i if filters.year_start
      @criteria["first_year_published_lt"] = filters.year_end.to_i if filters.year_end
      if sent?(:year)
        @applied[:year] = filters.year_start.to_i
      else
        @applied[:published_start] = filters.year_start.to_i if sent?(:published_start)
        @applied[:published_end] = filters.year_end.to_i if sent?(:published_end)
      end
    end

    def apply_ranking
      ranked = parse_enum(:ranked, RANKED_VALUES, "all")
      rank_min = rank_bound(:rank_min)
      rank_max = rank_bound(:rank_max)
      raise Api::Page::InvalidParameter, "rank_min cannot be greater than rank_max" if rank_min && rank_max && rank_min > rank_max
      raise Api::Page::InvalidParameter, "rank_min and rank_max cannot be combined with ranked=unranked" if ranked == "unranked" && (rank_min || rank_max)

      @applied[:ranked] = ranked if sent?(:ranked)
      @criteria["ranked"] = "false" if ranked == "unranked"
      @criteria["ranked"] = "true" if ranked == "ranked" || rank_min || rank_max
      if rank_min
        @criteria["min_ranked_position"] = rank_min
        @applied[:rank_min] = rank_min
      end
      return unless rank_max

      @criteria["max_ranked_position"] = rank_max
      @applied[:rank_max] = rank_max
    end

    def rank_bound(name)
      return nil unless sent?(name)

      Api::Page.integer(@params[name], name: name.to_s, default: nil, min: 1)
    end

    def apply_hide_read
      value = sent?(:hide_read) ? @params[:hide_read].to_s : "false"
      raise Api::Page::InvalidParameter, "hide_read must be true or false" unless %w[true false].include?(value)

      @criteria["hide_read"] = value
      @applied[:hide_read] = true if value == "true"
    end

    def list_of(name) = @params[name].to_s.split(",").map(&:strip).reject(&:blank?).uniq

    def sent?(name) = @params.key?(name)
  end
end
