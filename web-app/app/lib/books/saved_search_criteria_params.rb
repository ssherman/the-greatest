# frozen_string_literal: true

module Books
  # Form params -> the criteria hash we store. The mirror image of
  # SavedSearchCriteria, which READS the column: this writes it.
  #
  # SavedSearchCriteria stays tolerant of both storage shapes and must not be
  # narrowed on the strength of this class -- 4,727 migrated rows will never
  # pass through here. What this buys is that a criterion is either absent or
  # valid in every row the form creates, so `#unparseable?` (which makes the
  # query match nothing, by design) is unreachable from the UI.
  #
  # `ranked` is stored as the string "true"/"false" because that is what all
  # 4,391 migrated rows store. The reader accepts a real boolean too; using one
  # here would just put two shapes in one column.
  class SavedSearchCriteriaParams
    SCALAR_INT_KEYS = %w[book_type first_year_published_gt first_year_published_lt max_ranked_position].freeze
    ID_ARRAY_KEYS = ::Books::SavedSearchCriteria::ID_ARRAY_KEYS

    def self.call(raw)
      new(raw).call
    end

    def initialize(raw)
      @raw = normalize_input(raw)
    end

    def call
      out = {}

      SCALAR_INT_KEYS.each do |key|
        value = integer_or_nil(@raw[key])
        out[key] = value unless value.nil?
      end

      ID_ARRAY_KEYS.each do |key|
        ids = Array(@raw[key]).filter_map { |v| integer_or_nil(v) }.uniq
        out[key] = ids if ids.any?
      end

      lengths = Array(@raw["book_length"]).filter_map { |v| integer_or_nil(v) }
        .uniq.select { |v| ::Books::Book.book_lengths.value?(v) }
      out["book_length"] = lengths if lengths.any?

      out["ranked"] = @raw["ranked"].to_s if %w[true false].include?(@raw["ranked"].to_s)
      out["hide_read"] = true if ActiveModel::Type::Boolean.new.cast(@raw["hide_read"])
      out["genre_match_mode"] = "all" if @raw["genre_match_mode"].to_s == "all"

      out
    end

    private

    # Accepts a permitted ActionController::Parameters as well as a plain hash;
    # to_h on an unpermitted Parameters raises, which is the correct failure.
    def normalize_input(raw)
      return {} if raw.nil?

      (raw.respond_to?(:to_unsafe_h) ? raw.to_h : raw).stringify_keys
    end

    # Integer(..., exception: false) rather than to_i: "abc".to_i is 0, which is
    # a valid book_type (Fiction) and a valid book_length.
    def integer_or_nil(value)
      return nil if value.nil? || value.to_s.strip.empty?

      Integer(value, exception: false)
    end
  end
end
