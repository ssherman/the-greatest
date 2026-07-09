module Services
  module BooksMigration
    # Legacy `lists` -> STI Books::List, preserving id. Bulk upsert_all bypasses the List
    # callbacks — crucially before_save :auto_simplify_content, which would re-run the HTML
    # simplifier over raw_content and overwrite the legacy formatted_text we preserve as
    # simplified_content — and the validations. status is symbol-remapped (old/new enums
    # differ: active/rejected swap ints, inactive/pending collapse to unapproved).
    # raw_content <- raw_html, simplified_content <- formatted_text, items_json skipped
    # (nil; real items live in list_items). Legacy created_at/updated_at preserved.
    # Idempotent on id.
    class ListMigrator < BulkUpsertMigrator
      STATUS_MAP = {0 => 0, 1 => 1, 2 => 3, 3 => 2, 4 => 0, 5 => 0}.freeze

      private

      def legacy_model
        LegacyBooks::List
      end

      def model_key
        "Books::List"
      end

      def target_model
        List
      end

      def unique_by
        :id
      end

      def record_timestamps?
        false
      end

      def build_rows(attrs)
        [{
          id: attrs["id"],
          type: "Books::List",
          name: attrs["name"],
          description: attrs["description"],
          source: attrs["source"],
          url: attrs["url"],
          status: remap_status(attrs["status"]),
          year_published: attrs["year_published"],
          number_of_voters: attrs["number_of_voters"],
          estimated_quality: attrs["estimated_quality"],
          submitted_by_id: attrs["submitted_by_id"],
          high_quality_source: attrs["high_quality_source"],
          category_specific: attrs["category_specific"],
          location_specific: attrs["location_specific"],
          yearly_award: attrs["yearly_award"],
          voter_count_unknown: attrs["voter_count_unknown"],
          voter_names_unknown: attrs["voter_names_unknown"],
          raw_content: attrs["raw_html"],
          simplified_content: attrs["formatted_text"],
          created_at: attrs["created_at"],
          updated_at: attrs["updated_at"]
        }]
      end

      def remap_status(old)
        STATUS_MAP.fetch(old) { raise "unmapped legacy lists.status=#{old.inspect}" }
      end
    end
  end
end
