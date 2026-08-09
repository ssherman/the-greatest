# frozen_string_literal: true

module Books
  # Typed readers over a saved search's raw criteria hash. No database, no
  # OpenSearch -- everything here is a pure read of the stored jsonb.
  #
  # Every reader accepts BOTH storage shapes on purpose. Migrated rows store
  # book_type as an Integer and ranked as the string "true"; a form POSTs "0"
  # and "true" as strings. Normalizing on write was the alternative and is
  # worse: it is a step a future writer can forget, and it would need a data
  # migration for the 4,727 rows already stored.
  class SavedSearchCriteria
    ID_ARRAY_KEYS = %w[
      included_category_ids excluded_category_ids
      included_language_ids excluded_language_ids
      included_country_ids excluded_country_ids
    ].freeze

    def initialize(raw)
      @raw = raw || {}
    end

    ID_ARRAY_KEYS.each do |key|
      define_method(key) { int_array(key) }
    end

    def book_type
      int_or_nil("book_type")
    end

    # Values outside the enum are dropped rather than rendered or queried:
    # Books::Book.book_lengths is an in-memory hash, so this costs no query.
    def book_length
      int_array("book_length").select { |value| ::Books::Book.book_lengths.value?(value) }
    end

    def first_year_published_gt
      int_or_nil("first_year_published_gt")
    end

    def first_year_published_lt
      int_or_nil("first_year_published_lt")
    end

    # Tri-state, deliberately not a boolean: nil means "the whole corpus" and
    # :unranked means "unranked only". Legacy's "All Books" option submits "",
    # which reads as nil. Collapsing nil and :unranked would silently change
    # what 437 stored searches return.
    def ranked
      case @raw["ranked"]
      when "true", true then :ranked
      when "false", false then :unranked
      end
    end

    def genre_match_mode
      (@raw["genre_match_mode"].to_s == "all") ? :all : :any
    end

    def hide_read
      value = @raw["hide_read"]
      value == true || value.to_s == "true"
    end

    def max_ranked_position
      int_or_nil("max_ranked_position")
    end

    private

    # Integer(…, exception: false) rather than to_i: "abc".to_i is 0, which is
    # a valid book_type (Fiction) and a valid book_length. Silent corruption.
    def int_or_nil(key)
      value = @raw[key]
      return nil if value.nil?

      Integer(value, exception: false)
    end

    def int_array(key)
      Array(@raw[key]).filter_map { |value| Integer(value, exception: false) }
    end
  end
end
