module Services
  module BooksMigration
    # Verifies imported goal definitions and reports intentional membership
    # repairs without persisting either legacy joins or stored percentages.
    class ReadingGoalVerification
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      EXPECTED_DEFINITION_TOTALS = {
        imported_goals: 399,
        distinct_owners: 374,
        public_goals: 8,
        id_range: 1..438
      }.freeze
      RESERVED_ID_FLOOR = ReadingGoalMigrator::RESERVED_ID_FLOOR
      FORBIDDEN_JOIN_TABLES = %w[reading_goal_books books_reading_goal_books].freeze
      FORBIDDEN_PERCENTAGE_COLUMNS = %w[percentage percentage_done].freeze

      def self.call = new.call

      def call
        legacy_goals = LegacyBooks::ReadingGoal.all.to_a
        legacy_ids = legacy_goals.map(&:id)
        imported_scope = ::Books::ReadingGoal.where(id: legacy_ids)

        missing_owner_count = missing_owner_count(legacy_goals)
        unexpected_low_ids = ::Books::ReadingGoal
          .where(id: ...RESERVED_ID_FLOOR)
          .where.not(id: legacy_ids)
          .order(:id)
          .pluck(:id)
        repairs = repair_counts(legacy_goals)
        persisted_goal_book_rows = persisted_goal_book_rows()
        persisted_percentage_columns = (
          ::Books::ReadingGoal.column_names & FORBIDDEN_PERCENTAGE_COLUMNS
        ).size

        data = {
          imported_goals: imported_scope.count,
          distinct_owners: imported_scope.distinct.count(:user_id),
          public_goals: imported_scope.public_goals.count,
          id_range: imported_scope.minimum(:id)..imported_scope.maximum(:id),
          missing_imported_owners: missing_owner_count,
          unexpected_low_target_ids: unexpected_low_ids,
          persisted_goal_book_rows: persisted_goal_book_rows,
          persisted_percentage_columns: persisted_percentage_columns,
          repairs: repairs
        }
        errors = definition_errors(data)

        Result.new(success?: errors.empty?, data: data, errors: errors)
      end

      private

      def expected_definition_totals
        EXPECTED_DEFINITION_TOTALS
      end

      def missing_owner_count(legacy_goals)
        owner_ids = legacy_goals.map(&:user_id).uniq
        migrated_owner_ids = ::User.where(id: owner_ids).pluck(:id)
        (owner_ids - migrated_owner_ids).size
      end

      def repair_counts(legacy_goals)
        stale_count = 0
        disagreement_count = 0
        missing_count = 0
        drift_count = 0

        legacy_goals.each do |legacy_goal|
          legacy_memberships = LegacyBooks::ReadingGoalBook
            .where(reading_goal_id: legacy_goal.id)
            .pluck(:book_id, :read_date)
            .to_h
          read_list_id = ::Books::UserList
            .where(user_id: legacy_goal.user_id, list_type: :read)
            .pick(:id)
          canonical = if read_list_id
            ::UserListItem
              .where(user_list_id: read_list_id, listable_type: "Books::Book")
              .pluck(:listable_id, :completed_on)
              .to_h
          else
            {}
          end
          projected = canonical.select do |_book_id, completed_on|
            completed_on.present? &&
              (legacy_goal.start_date..legacy_goal.end_date).cover?(completed_on)
          end

          stale_count += legacy_memberships.keys.count { |book_id| !canonical.key?(book_id) }
          disagreement_count += legacy_memberships.count do |book_id, read_date|
            canonical.key?(book_id) && canonical[book_id] != read_date
          end
          missing_count += (projected.keys - legacy_memberships.keys).size
          derived_percentage = (
            legacy_memberships.size.fdiv(legacy_goal.number_of_books) * 100
          ).round(2)
          stored_percentage = if legacy_goal.percentage_done.nil?
            BigDecimal(0)
          else
            BigDecimal(legacy_goal.percentage_done.to_s)
          end
          drift_count += 1 unless stored_percentage == BigDecimal(derived_percentage.to_s)
        end

        {
          stale_memberships: stale_count,
          date_disagreements: disagreement_count,
          missing_qualifying_books: missing_count,
          percentage_drift: drift_count
        }
      end

      def persisted_goal_book_rows
        connection = ::Books::ReadingGoal.connection
        FORBIDDEN_JOIN_TABLES.sum do |table|
          next 0 unless connection.data_source_exists?(table)

          quoted_table = connection.quote_table_name(table)
          connection.select_value("SELECT COUNT(*) FROM #{quoted_table}").to_i
        end
      end

      def definition_errors(data)
        expected = expected_definition_totals
        errors = []
        errors << "expected #{expected[:imported_goals]} imported goals, found #{data[:imported_goals]}" if data[:imported_goals] != expected[:imported_goals]
        errors << "expected #{expected[:distinct_owners]} distinct owners, found #{data[:distinct_owners]}" if data[:distinct_owners] != expected[:distinct_owners]
        errors << "expected #{expected[:public_goals]} public goals, found #{data[:public_goals]}" if data[:public_goals] != expected[:public_goals]
        errors << "expected imported id range #{expected[:id_range]}, found #{data[:id_range]}" if data[:id_range] != expected[:id_range]
        if data[:missing_imported_owners].positive?
          errors << "#{data[:missing_imported_owners]} legacy goal owners have no migrated User"
        end
        if data[:unexpected_low_target_ids].any?
          errors << "unexpected target ids below #{RESERVED_ID_FLOOR}: #{data[:unexpected_low_target_ids].join(", ")}"
        end
        if data[:persisted_goal_book_rows].positive?
          errors << "target schema contains #{data[:persisted_goal_book_rows]} persisted reading-goal membership rows"
        end
        if data[:persisted_percentage_columns].positive?
          errors << "target schema contains #{data[:persisted_percentage_columns]} persisted percentage columns"
        end
        errors
      end
    end
  end
end
