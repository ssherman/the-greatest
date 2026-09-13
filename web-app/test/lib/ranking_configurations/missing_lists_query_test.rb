# frozen_string_literal: true

require "test_helper"

module RankingConfigurations
  class MissingListsQueryTest < ActiveSupport::TestCase
    setup do
      @entry = Registry.find(:books, "books")
      @primary = ranking_configurations(:books_global)
      @config = ranking_configurations(:books_user)
      @in_primary = Books::List.create!(name: "Official only", source: "Test", status: :active)
      @in_both = Books::List.create!(name: "In both", source: "Test", status: :active)
      @inactive = Books::List.create!(name: "Inactive official", source: "Test", status: :approved)
      RankedList.create!(list: @in_primary, ranking_configuration: @primary, weight: 80)
      RankedList.create!(list: @in_both, ranking_configuration: @primary, weight: 60)
      RankedList.create!(list: @inactive, ranking_configuration: @primary, weight: 40)
      RankedList.create!(list: @in_both, ranking_configuration: @config)
    end

    test "returns the primary's active lists the configuration does not have, heaviest first" do
      rows = MissingListsQuery.call(config: @config, entry: @entry).to_a

      assert_includes rows.map(&:list), @in_primary
      refute_includes rows.map(&:list), @in_both
      refute_includes rows.map(&:list), @inactive
      assert_equal rows.map(&:weight), rows.map(&:weight).sort.reverse
      assert rows.all? { |row| row.ranking_configuration_id == @primary.id }
    end

    test "is empty once the configuration has every official list" do
      @config.ranked_lists.create!(list: @in_primary)
      assert_empty MissingListsQuery.call(config: @config, entry: @entry)
    end

    test "is empty when the domain has no primary" do
      @primary.update_columns(primary: false)
      assert_empty MissingListsQuery.call(config: @config, entry: @entry)
    end

    test "preloads lists" do
      relation = MissingListsQuery.call(config: @config, entry: @entry)
      assert_queries_count(1) { relation.to_a.each { |row| row.list.name } }
    end
  end
end
