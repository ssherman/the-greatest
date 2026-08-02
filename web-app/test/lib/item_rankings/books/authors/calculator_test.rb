require "test_helper"

module ItemRankings
  module Books
    module Authors
      class CalculatorTest < ActiveSupport::TestCase
        setup do
          @config = ranking_configurations(:books_authors_global)
          @source = ranking_configurations(:books_global)
          @calculator = ItemRankings::Books::Authors::Calculator.new(@config)

          @source.ranked_items.destroy_all
          @config.ranked_items.destroy_all

          @tolstoy = books_authors(:tolstoy)
          @king = books_authors(:king)
          @placeholder = books_authors(:excluded_placeholder)
        end

        def rank_book(book, score)
          RankedItem.create!(
            item: book,
            ranking_configuration: @source,
            rank: @source.ranked_items.count + 1,
            score: score
          )
        end

        def credit(book, author, role: :author)
          ::Books::BookAuthor.find_or_create_by!(book: book, author: author) do |ba|
            ba.role = role
          end.tap { |ba| ba.update!(role: role) }
        end

        test "item_type returns Books::Author" do
          assert_equal "Books::Author", @calculator.send(:item_type)
        end

        test "list_type raises NotImplementedError" do
          assert_raises(NotImplementedError) { @calculator.send(:list_type) }
        end

        test "writes ranked items ordered by score with sequential ranks" do
          credit(books_books(:war_and_peace), @tolstoy)
          credit(books_books(:crime_and_punishment), @tolstoy)
          credit(books_books(:got), @king)
          rank_book(books_books(:war_and_peace), 100)
          rank_book(books_books(:crime_and_punishment), 100)
          rank_book(books_books(:got), 50)

          result = @calculator.call

          assert result.success?, "expected success, got #{result.errors}"

          items = @config.ranked_items.order(:rank)
          assert_equal [1, 2], items.pluck(:rank)
          assert_equal @tolstoy.id, items.first.item_id
          scores = items.pluck(:score)
          assert_equal scores.sort.reverse, scores
        end

        test "applies the count multiplier" do
          credit(books_books(:war_and_peace), @tolstoy)
          rank_book(books_books(:war_and_peace), 1000)

          @calculator.call

          item = @config.ranked_items.find_by(item: @tolstoy)
          assert_in_delta 305.6, item.score, 0.1
        end

        test "excludes editor credits" do
          credit(books_books(:war_and_peace), @king, role: :editor)
          rank_book(books_books(:war_and_peace), 100)

          @calculator.call

          assert_nil @config.ranked_items.find_by(item: @king)
        end

        test "excludes authors flagged exclude_from_rankings" do
          credit(books_books(:war_and_peace), @placeholder)
          rank_book(books_books(:war_and_peace), 100)

          @calculator.call

          assert_nil @config.ranked_items.find_by(item: @placeholder)
        end

        test "ignores books with a non-positive score" do
          credit(books_books(:war_and_peace), @tolstoy)
          rank_book(books_books(:war_and_peace), 0)

          @calculator.call

          assert_nil @config.ranked_items.find_by(item: @tolstoy)
        end

        test "drops authors whose rounded score is zero" do
          credit(books_books(:war_and_peace), @tolstoy)
          rank_book(books_books(:war_and_peace), 0.01)

          @calculator.call

          assert_nil @config.ranked_items.find_by(item: @tolstoy)
        end

        test "breaks score ties by author id ascending" do
          credit(books_books(:war_and_peace), @tolstoy)
          credit(books_books(:got), @king)
          rank_book(books_books(:war_and_peace), 100)
          rank_book(books_books(:got), 100)

          @calculator.call

          items = @config.ranked_items.order(:rank)
          expected_order = [@tolstoy, @king].sort_by(&:id).map(&:id)
          assert_equal expected_order, items.pluck(:item_id)
        end

        test "deletes ranked items that no longer qualify" do
          credit(books_books(:war_and_peace), @tolstoy)
          rank_book(books_books(:war_and_peace), 100)
          @calculator.call
          assert @config.ranked_items.find_by(item: @tolstoy)

          @source.ranked_items.reload.destroy_all
          credit(books_books(:got), @king)
          rank_book(books_books(:got), 100)
          @calculator.call

          assert_nil @config.ranked_items.find_by(item: @tolstoy)
          assert @config.ranked_items.find_by(item: @king)
        end

        test "fails without deleting when there are no qualifying ranked books" do
          credit(books_books(:war_and_peace), @tolstoy)
          rank_book(books_books(:war_and_peace), 100)
          @calculator.call
          assert @config.ranked_items.find_by(item: @tolstoy)

          @source.ranked_items.reload.destroy_all

          result = @calculator.call

          assert_not result.success?
          assert_not_empty result.errors
          assert @config.ranked_items.find_by(item: @tolstoy), "expected the prior ranking to survive an empty recalculation"
        end

        test "is idempotent" do
          credit(books_books(:war_and_peace), @tolstoy)
          rank_book(books_books(:war_and_peace), 100)

          @calculator.call
          first = @config.ranked_items.order(:rank).pluck(:item_id, :rank, :score)
          @calculator.call
          second = @config.ranked_items.order(:rank).pluck(:item_id, :rank, :score)

          assert_equal first, second
        end

        test "fails without writing when there is no primary books configuration" do
          credit(books_books(:war_and_peace), @tolstoy)
          rank_book(books_books(:war_and_peace), 100)
          @source.update!(primary: false)

          result = @calculator.call

          assert_not result.success?
          assert_not_empty result.errors
          assert_equal 0, @config.ranked_items.count
        end
      end
    end
  end
end
