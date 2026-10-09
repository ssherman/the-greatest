module Services
  module BooksMigration
    # Imports only legacy reading-goal definitions. Goal membership and progress
    # remain a live projection of dated Books Read-list items; the legacy join
    # rows and stored percentage are deliberately not persisted.
    class ReadingGoalMigrator < BulkUpsertMigrator
      RESERVED_ID_FLOOR = 10_000

      private

      def legacy_model
        LegacyBooks::ReadingGoal
      end

      def model_key
        "Books::ReadingGoal"
      end

      def target_model
        ::Books::ReadingGoal
      end

      def unique_by
        :id
      end

      def record_timestamps?
        false
      end

      def preload_context
        @user_ids = ::User.pluck(:id).to_set
        @legacy_goal_ids = legacy_model.pluck(:id)

        maximum_legacy_id = @legacy_goal_ids.max
        if maximum_legacy_id && maximum_legacy_id >= RESERVED_ID_FLOOR
          raise "legacy reading goal id #{maximum_legacy_id} reaches reserved id floor #{RESERVED_ID_FLOOR}"
        end

        @preflight_rows = nil
        rows = []
        legacy_each { |attrs| rows << attrs }
        @preflight_rows = rows
        @preflight_rows.each { |attrs| build_rows(attrs) }

        delete_orphaned_goals
      end

      # The table's sequence starts at the reserved floor, so every id below it
      # came from an earlier pass of this migration. One that legacy no longer
      # holds is a goal its owner deleted on the live legacy site since then.
      # Runs only after every legacy row has validated, so a failed preflight
      # deletes nothing.
      def delete_orphaned_goals
        orphans = target_model
          .where(id: ...RESERVED_ID_FLOOR)
          .where.not(id: @legacy_goal_ids)
        @orphaned_goal_ids = orphans.order(:id).pluck(:id)
        # An empty legacy table (a restore in progress) would delete every goal.
        # The table is a few hundred rows, under guard_deletion!'s floor, so this
        # checks for the empty table directly.
        if @legacy_goal_ids.empty? && @orphaned_goal_ids.any?
          raise "legacy has no reading goals but #{@orphaned_goal_ids.size} are here; " \
            "refusing to delete them all (check the legacy database)"
        end
        orphans.delete_all if @orphaned_goal_ids.any?
      end

      def extra_result_data
        {orphaned_goals_deleted: @orphaned_goal_ids}
      end

      # The legacy corpus is intentionally small (a few hundred rows). Materializing it lets
      # preload_context validate every definition before BulkUpsertMigrator can
      # commit its first 1,000-row batch.
      def legacy_each(&block)
        return @preflight_rows.each(&block) if @preflight_rows

        super
      end

      def build_rows(attrs)
        legacy_id = attrs["id"]
        user_id = attrs["user_id"]
        name = attrs["name"]
        target_count = attrs["number_of_books"]
        starts_on = attrs["start_date"]
        ends_on = attrs["end_date"]

        raise "no migrated User for legacy reading_goals.user_id=#{user_id.inspect}" unless @user_ids.include?(user_id)
        raise "blank name for legacy reading goal id=#{legacy_id}" if name.blank?
        unless target_count.to_i.positive?
          raise "non-positive number_of_books=#{target_count.inspect} for legacy reading goal id=#{legacy_id}"
        end
        if starts_on.blank? || ends_on.blank?
          raise "start_date and end_date are required for legacy reading goal id=#{legacy_id}"
        end
        if ends_on < starts_on
          raise "end_date precedes start_date for legacy reading goal id=#{legacy_id}"
        end

        [{
          id: legacy_id,
          user_id: user_id,
          name: name,
          description: attrs["description"],
          target_count: target_count,
          starts_on: starts_on,
          ends_on: ends_on,
          public: attrs["public"] || false,
          created_at: attrs["created_at"],
          updated_at: attrs["updated_at"]
        }]
      end

      def finalize
        connection = target_model.connection
        next_id = [RESERVED_ID_FLOOR, target_model.maximum(:id).to_i + 1].max
        sequence = connection.select_value(
          "SELECT pg_get_serial_sequence('books_reading_goals', 'id')"
        )
        connection.execute(
          "SELECT setval(#{connection.quote(sequence)}, #{next_id}, false)"
        )
      end
    end
  end
end
