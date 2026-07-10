require "test_helper"

module Services
  module BooksMigration
    class RankedListMigratorTest < ActiveSupport::TestCase
      MODEL_KEY = "Books::RankingConfiguration"

      setup do
        @rc = Books::RankingConfiguration.create!(name: "RL Config")
        @list = Books::List.create!(name: "RL List")
        LegacyIdMap.record(model: MODEL_KEY, legacy_id: 9100, new_id: @rc.id)
      end

      def run_migrator(rows)
        m = RankedListMigrator.new
        m.stubs(:legacy_each).multiple_yields(*rows.zip)
        m.call
      end

      def legacy_row(overrides = {})
        {
          "id" => 7000001,
          "ranking_configuration_id" => 9100,
          "list_id" => @list.id,
          "weight" => 42,
          "created_at" => Time.utc(2020, 1, 2, 3, 4, 5),
          "updated_at" => Time.utc(2021, 2, 3, 4, 5, 6)
        }.merge(overrides)
      end

      test "maps a legacy ranked_list, mapping the rc id and preserving weight + timestamps" do
        result = run_migrator([legacy_row])
        assert result[:success], result[:error]
        rl = RankedList.find_by(list_id: @list.id, ranking_configuration_id: @rc.id)
        assert_not_nil rl
        assert_equal 42, rl.weight
        assert_equal Time.utc(2020, 1, 2, 3, 4, 5), rl.created_at
        assert_equal Time.utc(2021, 2, 3, 4, 5, 6), rl.updated_at
      end

      test "fails loud when the list is not migrated" do
        missing = List.maximum(:id).to_i + 999_999
        result = run_migrator([legacy_row("id" => 7000042, "list_id" => missing)])
        refute result[:success]
        assert_match(/7000042/, result[:error])
      end

      test "fails loud when the ranking configuration is not mapped" do
        result = run_migrator([legacy_row("id" => 7000043, "ranking_configuration_id" => 999_999)])
        refute result[:success]
        assert_match(/7000043/, result[:error])
      end

      test "fails loud when no ranking configuration has been migrated" do
        LegacyIdMap.where(model: MODEL_KEY).delete_all
        result = run_migrator([legacy_row])
        refute result[:success]
        assert_match(/ranking_configuration/, result[:error])
      end

      test "is idempotent on [list_id, ranking_configuration_id]" do
        run_migrator([legacy_row])
        assert_no_difference -> { RankedList.count } do
          run_migrator([legacy_row("weight" => 99)])
        end
        assert_equal 99, RankedList.find_by(list_id: @list.id, ranking_configuration_id: @rc.id).weight
      end
    end
  end
end
