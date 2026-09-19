# frozen_string_literal: true

require "test_helper"

module CsvExports
  class RankedItemsTest < ActiveSupport::TestCase
    setup do
      @config = ranking_configurations(:games_global)
      @relation = Registry.for_config(@config).relation.call(@config)
      @row_class = Games::RankedGameRow
    end

    def export(limit:)
      io = StringIO.new
      rows = RankedItems.call(relation: @relation, row_class: @row_class, limit: limit, io: io)
      [rows, CSV.parse(io.string.delete_prefix(Writer::BOM))]
    end

    test "writes every ranked item in rank order with the header" do
      rows, parsed = export(limit: nil)

      assert_equal 4, rows
      assert_equal Games::RankedGameRow::HEADERS, parsed.first
      assert_equal %w[1 2 3 4], parsed.drop(1).map(&:first)
      assert_equal "The Legend of Zelda: Breath of the Wild", parsed[1][3]
    end

    test "the limit caps the rows written" do
      rows, parsed = export(limit: 2)

      assert_equal 2, rows
      assert_equal 3, parsed.size
    end

    test "rank order survives batching" do
      stub_const_batch(2) do
        _rows, parsed = export(limit: nil)
        assert_equal %w[1 2 3 4], parsed.drop(1).map(&:first)
      end
    end

    test "a ranked item whose item is gone is skipped, not raised" do
      RankedItem.where(item: games_games(:half_life_2)).delete_all
      RankedItem.insert_all([{item_type: "Games::Game", item_id: -1, ranking_configuration_id: @config.id,
                              rank: 3, score: 1, created_at: Time.current, updated_at: Time.current}])

      rows, parsed = export(limit: nil)

      assert_equal 3, rows
      assert_equal %w[1 2 4], parsed.drop(1).map(&:first)
    end

    test "the relation's own includes do not break the id pluck" do
      config = ranking_configurations(:books_global)
      RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: config, rank: 1, score: 1)
      io = StringIO.new

      rows = RankedItems.call(relation: Registry.for_config(config).relation.call(config),
        row_class: Books::RankedBookRow, limit: nil, io: io)

      assert_equal 1, rows
    end

    private

    def stub_const_batch(size)
      original = RankedItems::BATCH
      RankedItems.send(:remove_const, :BATCH)
      RankedItems.const_set(:BATCH, size)
      yield
    ensure
      RankedItems.send(:remove_const, :BATCH)
      RankedItems.const_set(:BATCH, original)
    end
  end
end
