# frozen_string_literal: true

require "test_helper"

module RankingConfigurations
  class PenaltyRowsTest < ActiveSupport::TestCase
    setup do
      @entry = Registry.find(:books, "books")
      # global_penalty is static; the catalogue only lists a static penalty
      # tagged on an active list of the entry's kind.
      active = Books::List.create!(name: "Active tagged list", source: "T", status: :active)
      ListPenalty.create!(list: active, penalty: penalties(:global_penalty))
    end

    test "returns every catalogue penalty for the entry, grouped by category title" do
      groups = PenaltyRows.call(entry: @entry, values: {})

      rows = groups.flat_map(&:rows)
      assert_equal Registry.penalties_for(@entry).count, rows.size
      assert_includes rows.map(&:penalty), penalties(:books_penalty)
      refute_includes rows.map(&:penalty), penalties(:user_penalty)
      assert groups.all? { |group| group.title.present? && group.rows.any? }
    end

    test "marks a penalty enabled with its value when it appears in values, off with 0 otherwise" do
      on = penalties(:books_penalty)
      groups = PenaltyRows.call(entry: @entry, values: {on.id => 40})
      rows = groups.flat_map(&:rows).index_by(&:penalty)

      assert rows[on].enabled
      assert_equal 40, rows[on].value
      refute rows[penalties(:global_penalty)].enabled
      assert_equal 0, rows[penalties(:global_penalty)].value
    end

    test "orders groups by Penalty::CATEGORY_TITLES with uncategorized last" do
      groups = PenaltyRows.call(entry: @entry, values: {})
      titles = groups.map(&:title)
      expected_order = ::Penalty::CATEGORY_TITLES.values + ["Other"]

      assert_equal titles, expected_order.select { |title| titles.include?(title) }
    end
  end
end
