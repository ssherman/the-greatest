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
    #
    # Three legacy lists are deliberately NOT imported: they are superseded by
    # the generated "Our Users' Favorite ..." list that
    # Services::Lists::GenerateUserFavorites rebuilds nightly from live user
    # favorites. See SUPERSEDED_LIST_NAMES.
    class ListMigrator < BulkUpsertMigrator
      STATUS_MAP = {0 => 0, 1 => 1, 2 => 3, 3 => 2, 4 => 0, 5 => 0}.freeze

      # Legacy lists superseded by the generated users' favorites list.
      #
      # The legacy site froze user favorites into three hand-maintained lists: a
      # top 100, a 6,933-item "honorable mention" holding everything from 101
      # down, and an older stale artifact. All three are now derived data --
      # GenerateUserFavorites recomputes the single generated list from
      # user_lists on every run -- so re-importing them resurrects three stale
      # copies of the same votes on every `data_migration:all`.
      #
      # The third name is load-bearing in a second way: it is exactly
      # ::Books::UserList.generated_list_name, so importing it would collide with
      # the generated list on the (type, auto_generated_kind) partial unique
      # index the moment anyone tried to adopt it.
      #
      # Rows are dropped here rather than filtered in legacy_each because the
      # names are only known per row, and because dropping in build_rows keeps
      # the exclusion in one place that list_items, ranked_lists and
      # list_penalties can all be tested against.
      SUPERSEDED_LIST_NAMES = [
        "Our Users' Top 100 Favorite Books of All Time",
        "Our Users' Honorable Mention Favorite Books of All Time",
        "Our Users' Favorite Books of All Time"
      ].freeze

      # The legacy ids of the lists SUPERSEDED_LIST_NAMES drops -- the ONLY
      # parents the child migrators (list_items, ranked_lists, list_penalties)
      # may find missing without failing loud.
      #
      # Resolved by name against the same legacy table build_rows drops on, so
      # the exclusion and the children's allowance can never disagree. Each child
      # migrator memoizes the result once per run in preload_context; there is
      # deliberately no class-level memo, which would outlive the run and go
      # stale.
      #
      # The alternative -- "skip any missing parent" -- is what this replaces,
      # and it was unsafe: BulkUpsertMigrator commits each batch independently,
      # so a ListMigrator that failed after its first batch leaves a NON-EMPTY
      # set of imported lists, and a blanket skip then silently discards the
      # children of every ordinary list it never reached while reporting success.
      def self.superseded_legacy_list_ids
        LegacyBooks::List.where(name: SUPERSEDED_LIST_NAMES).pluck(:id).to_set
      end

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
        return [] if SUPERSEDED_LIST_NAMES.include?(attrs["name"])

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
          activated_at: (remap_status(attrs["status"]) == 3) ? attrs["updated_at"] : nil,
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
