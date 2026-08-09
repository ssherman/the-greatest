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

    # The criteria `#unparseable?` applies to: the id arrays, book_type,
    # book_length, the publication-year bounds, and max_ranked_position. NOT
    # `ranked` (its blank state IS "All Books", not a failure -- see #ranked),
    # NOT `genre_match_mode` (defaults to :any by design, no invalid state),
    # NOT `hide_read` (a boolean cast has no unparseable state).
    UNPARSEABLE_KEYS = (ID_ARRAY_KEYS + %w[
      book_type book_length first_year_published_gt first_year_published_lt max_ranked_position
    ]).freeze

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

    # ActiveModel's cast is what legacy used, and it is what makes a Rails
    # check_box ("1") and a bare HTML checkbox ("on") read as true. Rejects
    # "0"/"false"/"off"/""/nil correctly. `!!` because cast returns nil, not
    # false, for a blank value.
    def hide_read
      !!ActiveModel::Type::Boolean.new.cast(@raw["hide_read"])
    end

    def max_ranked_position
      int_or_nil("max_ranked_position")
    end

    # A criterion the user actually set, which does not parse -- book_type
    # "abc", included_category_ids ["abc"]. Distinguished from an ABSENT
    # criterion so the query can match nothing rather than silently
    # broadening to the whole corpus (spec §6). A blank raw value ("" / nil /
    # [] / [""]) counts as absent, not invalid; a value that parses to
    # *something* (even a valid id that matches no record, like category
    # 999999) is not invalid either -- only a present value that parses to
    # nothing at all is.
    def unparseable?(key)
      key = key.to_s
      unless UNPARSEABLE_KEYS.include?(key)
        raise ArgumentError, "#unparseable? does not apply to #{key.inspect}"
      end
      return false if blank_raw?(@raw[key])

      send(key).blank?
    end

    private

    # Array(value).all?(&:blank?) so a scalar ("abc"), an all-blank array
    # (["", nil]), and true blanks (nil, "", []) are all "nothing was set" --
    # the array case matters because ["", nil] must read the same as [] does
    # elsewhere in this class.
    def blank_raw?(value)
      Array(value).all? { |entry| entry.to_s.strip.empty? }
    end

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
