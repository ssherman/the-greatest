require "test_helper"

module Services
  module BooksMigration
    class ReadingGoalMigratorTest < ActiveSupport::TestCase
      setup do
        ::Books::ReadingGoal.delete_all
        @user = users(:regular_user)
        @legacy_created_at = Time.utc(2018, 5, 6, 7, 8, 9)
        @legacy_updated_at = Time.utc(2019, 6, 7, 8, 9, 10)
      end

      def legacy_row(overrides = {})
        {
          "id" => 438,
          "user_id" => @user.id,
          "name" => "500 by 2035",
          "description" => "Long goal",
          "number_of_books" => 500,
          "start_date" => Date.new(2020, 1, 1),
          "end_date" => Date.new(2035, 12, 31),
          "public" => true,
          "percentage_done" => BigDecimal("17.25"),
          "created_at" => @legacy_created_at,
          "updated_at" => @legacy_updated_at
        }.merge(overrides)
      end

      def run_migrator(rows, legacy_ids: rows.map { |row| row.fetch("id") })
        LegacyBooks::ReadingGoal.stubs(:pluck).with(:id).returns(legacy_ids)
        migrator = ReadingGoalMigrator.new
        migrator.stubs(:legacy_each).multiple_yields(*rows.zip)
        migrator.call
      end

      test "maps the approved definition columns and drops stored percentage" do
        captured_row = nil
        ::Books::ReadingGoal.expects(:upsert_all).with do |rows, unique_by:, record_timestamps:|
          captured_row = rows.sole
          unique_by == :id && record_timestamps == false
        end

        result = run_migrator([legacy_row])

        assert result[:success], result[:error]
        assert_equal({
          id: 438,
          user_id: @user.id,
          name: "500 by 2035",
          description: "Long goal",
          target_count: 500,
          starts_on: Date.new(2020, 1, 1),
          ends_on: Date.new(2035, 12, 31),
          public: true,
          created_at: @legacy_created_at,
          updated_at: @legacy_updated_at
        }, captured_row.symbolize_keys)
        refute_includes captured_row.keys.map(&:to_s), "percentage_done"
      end

      test "coalesces a null public flag to false" do
        result = run_migrator([legacy_row("public" => nil)])

        assert result[:success], result[:error]
        assert_not ::Books::ReadingGoal.find(438).public?
      end

      test "rejects a goal whose owner has not been migrated" do
        result = run_migrator([legacy_row("user_id" => User.maximum(:id).to_i + 1_000_000)])

        refute result[:success]
        assert_match(/no migrated User/, result[:error])
      end

      test "validates every legacy goal before flushing the first batch" do
        rows = (1..1_001).map { |id| legacy_row("id" => id) }
        rows.last["user_id"] = User.maximum(:id).to_i + 1_000_000
        ::Books::ReadingGoal.expects(:upsert_all).never

        result = run_migrator(rows)

        refute result[:success]
        assert_match(/no migrated User/, result[:error])
        assert_equal 0, result.dig(:data, :count)
      end

      test "rejects non-positive targets" do
        [0, -1].each do |target|
          result = run_migrator([legacy_row("number_of_books" => target)])

          refute result[:success]
          assert_match(/positive number_of_books/, result[:error])
        end
      end

      test "rejects a missing start or end date" do
        %w[start_date end_date].each do |column|
          result = run_migrator([legacy_row(column => nil)])

          refute result[:success]
          assert_match(/start_date and end_date/, result[:error])
        end
      end

      test "rejects reversed dates" do
        result = run_migrator([legacy_row(
          "start_date" => Date.new(2035, 12, 31),
          "end_date" => Date.new(2020, 1, 1)
        )])

        refute result[:success]
        assert_match(/end_date precedes start_date/, result[:error])
      end

      test "rejects a blank name" do
        result = run_migrator([legacy_row("name" => "  ")])

        refute result[:success]
        assert_match(/blank name/, result[:error])
      end

      test "rejects legacy ids in the new-app reserved range before flushing" do
        ::Books::ReadingGoal.expects(:upsert_all).never

        result = run_migrator([legacy_row("id" => 10_000)])

        refute result[:success]
        assert_match(/legacy reading goal id 10000 reaches reserved id floor 10000/, result[:error])
      end

      test "rejects an unrelated existing low target id before flushing" do
        ::Books::ReadingGoal.create!(
          id: 437,
          user: @user,
          name: "New app collision",
          target_count: 1,
          starts_on: Date.new(2024, 1, 1),
          ends_on: Date.new(2024, 12, 31),
          public: false
        )
        ::Books::ReadingGoal.expects(:upsert_all).never

        result = run_migrator([legacy_row], legacy_ids: [438])

        refute result[:success]
        assert_match(/unexpected target ids below 10000: 437/, result[:error])
      end

      test "preserves timestamps and is idempotent on the legacy id" do
        first = run_migrator([legacy_row])
        assert first[:success], first[:error]

        assert_no_difference -> { ::Books::ReadingGoal.count } do
          second = run_migrator([legacy_row("name" => "Renamed")])
          assert second[:success], second[:error]
        end

        goal = ::Books::ReadingGoal.find(438)
        assert_equal "Renamed", goal.name
        assert_equal @legacy_created_at, goal.created_at
        assert_equal @legacy_updated_at, goal.updated_at
      end

      test "sets the next generated id at both the reserved floor and above the target maximum" do
        ::Books::ReadingGoal.create!(
          id: 15_000,
          user: @user,
          name: "Existing new-app goal",
          target_count: 12,
          starts_on: Date.new(2026, 1, 1),
          ends_on: Date.new(2026, 12, 31),
          public: false
        )
        maximum_before = ::Books::ReadingGoal.maximum(:id)

        result = run_migrator([legacy_row])
        assert result[:success], result[:error]

        generated = ::Books::ReadingGoal.create!(
          user: @user,
          name: "Generated after import",
          target_count: 12,
          starts_on: Date.new(2027, 1, 1),
          ends_on: Date.new(2027, 12, 31),
          public: false
        )
        assert_operator generated.id, :>=, 10_000
        assert_operator generated.id, :>=, maximum_before + 1
      end
    end
  end
end
