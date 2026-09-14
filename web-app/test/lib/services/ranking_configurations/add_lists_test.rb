# frozen_string_literal: true

require "test_helper"

module Services
  module RankingConfigurations
    class AddListsTest < ActiveSupport::TestCase
      setup do
        @entry = ::RankingConfigurations::Registry.find(:books, "books")
        @config = ranking_configurations(:books_user)
        @config.update_columns(needs_refresh: false)
        @active = ::Books::List.create!(name: "Active", source: "T", status: :active)
        @another = ::Books::List.create!(name: "Another", source: "T", status: :active)
        @approved = ::Books::List.create!(name: "Approved only", source: "T", status: :approved)
        @present = ::Books::List.create!(name: "Already there", source: "T", status: :active)
        ::RankedList.create!(list: @present, ranking_configuration: @config)
      end

      test "adds active lists of the entry's type that are not already present, once" do
        result = AddLists.call(config: @config, entry: @entry, list_ids: [@active.id, @another.id, @active.id])

        assert result.success?
        assert_equal 2, result.data[:added]
        assert_equal [@active.id, @another.id, @present.id].sort, @config.ranked_lists.pluck(:list_id).sort
        assert @config.reload.needs_refresh?
      end

      test "skips lists that are not active, already present, of another type, or nonsense" do
        games_list = lists(:games_list)

        result = AddLists.call(config: @config, entry: @entry, list_ids: [@approved.id, @present.id, games_list.id, "abc", -1, nil])

        assert result.success?
        assert_equal 0, result.data[:added]
        assert_equal [@present.id], @config.ranked_lists.pluck(:list_id)
        refute @config.reload.needs_refresh?, "nothing changed, so nothing is stale"
      end

      test "accepts string ids as posted by a form" do
        result = AddLists.call(config: @config, entry: @entry, list_ids: [@active.id.to_s])

        assert_equal 1, result.data[:added]
      end
    end
  end
end
