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

        unexpected_low_ids = target_model
          .where(id: ...RESERVED_ID_FLOOR)
          .where.not(id: @legacy_goal_ids)
          .order(:id)
          .pluck(:id)
        if unexpected_low_ids.any?
          raise "unexpected target ids below #{RESERVED_ID_FLOOR}: #{unexpected_low_ids.join(", ")}"
        end

        @preflight_rows = nil
        rows = []
        legacy_each { |attrs| rows << attrs }
        @preflight_rows = rows
        @preflight_rows.each { |attrs| build_rows(attrs) }
      end

      # The legacy corpus is intentionally small (399 rows). Materializing it lets
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
