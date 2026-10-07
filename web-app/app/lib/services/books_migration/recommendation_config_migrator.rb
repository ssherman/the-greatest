module Services
  module BooksMigration
    # Legacy recommendation_configs -> Books::RecommendationConfig, keyed on the
    # (preserved) user id. Legacy stored each preference in its own column; the
    # new row stores one criteria hash with the saved-search key names (spec §4.1).
    # exclude_locations has no equivalent and is dropped: the engine down-weights
    # locations instead of switching them off.
    class RecommendationConfigMigrator < Migrator
      LEGACY_BOOK_LENGTHS = {
        "very_short" => 0, "short" => 1, "medium" => 2, "moderate" => 3, "long" => 4, "very_long" => 5
      }.freeze

      def call
        @dropped_category_ids = []
        assert_book_length_enum!
        super
      rescue => e
        {success: false, error: e.message, data: {model: model_key, count: @count || 0}}
      end

      private

      def legacy_model
        LegacyBooks::RecommendationConfig
      end

      def model_key
        "Books::RecommendationConfig"
      end

      def assert_book_length_enum!
        return if ::Books::Book.book_lengths == LEGACY_BOOK_LENGTHS

        raise "book_length enum differs from legacy (#{::Books::Book.book_lengths.inspect}); " \
              "book_lengths cannot be copied by value"
      end

      def upsert_row(attrs)
        config = ::Books::RecommendationConfig.find_or_initialize_by(user_id: attrs["user_id"])
        config.criteria = transform_criteria(attrs)
        config.save!
      end

      def transform_criteria(attrs)
        out = {}
        lengths = Array(attrs["book_lengths"]).compact
        out["book_length"] = lengths if lengths.any?

        excluded = remap_category_ids(attrs["excluded_category_ids"])
        out["excluded_category_ids"] = excluded if excluded.any?

        included = remap_category_ids(attrs["included_category_ids"])
        out["included_category_ids"] = included if included.any?
        out["genre_match_mode"] = "all" if attrs["included_category_all"] && included.any?

        out["first_year_published_gt"] = attrs["published_year_start"] if attrs["published_year_start"]
        out["first_year_published_lt"] = attrs["published_year_end"] if attrs["published_year_end"]
        out["max_ranked_position"] = attrs["ranked_limit"] if attrs["ranked_limit"]
        out
      end

      def remap_category_ids(value)
        Array(value).compact.filter_map do |legacy_id|
          new_id = category_map[legacy_id.to_i]
          @dropped_category_ids << legacy_id.to_i if new_id.nil?
          new_id
        end
      end

      def category_map
        @category_map ||= LegacyIdMap.where(model: "Books::Category").pluck(:legacy_id, :new_id).to_h
      end

      def extra_result_data
        {dropped_category_ids: @dropped_category_ids.uniq}
      end
    end
  end
end
