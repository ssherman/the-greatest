# frozen_string_literal: true

require "test_helper"

module ItemRankings
  module Books
    class CalculatorTest < ActiveSupport::TestCase
      setup do
        @config = ranking_configurations(:books_global)
        @list = lists(:books_list)
        # books_list is the only list ranked by books_global. Its fixture item points
        # at a book that does not exist (see list_items.yml); replace it with two real
        # ones, and make the list active so prepare_lists reads it.
        @list.update!(status: :active)
        ListItem.where(list: @list).delete_all
        @catalog_book = books_books(:war_and_peace)
        @provisional_book = books_books(:got)
        ListItem.create!(list: @list, listable: @catalog_book, position: 1)
        ListItem.create!(list: @list, listable: @provisional_book, position: 2)
        @provisional_book.update!(provisional: true)
        RankedItem.where(ranking_configuration: @config).delete_all
      end

      test "ranks catalog books and leaves provisional books out" do
        result = ItemRankings::Books::Calculator.new(@config).call

        assert result.success?, "expected success, got #{result.errors}"
        ranked_ids = RankedItem.where(ranking_configuration: @config).pluck(:item_id)
        assert_includes ranked_ids, @catalog_book.id
        refute_includes ranked_ids, @provisional_book.id
      end

      test "a book ranked before it became provisional loses its ranked item" do
        RankedItem.create!(item: @provisional_book, ranking_configuration: @config, rank: 1, score: 100)

        ItemRankings::Books::Calculator.new(@config).call

        refute RankedItem.exists?(item: @provisional_book, ranking_configuration: @config)
      end
    end
  end
end
