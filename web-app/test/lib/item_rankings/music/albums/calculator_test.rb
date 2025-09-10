# frozen_string_literal: true

require "test_helper"

module ItemRankings
  module Music
    module Albums
      class CalculatorTest < ActiveSupport::TestCase
        def setup
          @ranking_configuration = ranking_configurations(:music_albums_global)
          @calculator = ItemRankings::Music::Albums::Calculator.new(@ranking_configuration)
        end

        # Test public methods

        test "initialize sets ranking configuration" do
          assert_equal @ranking_configuration, @calculator.ranking_configuration
        end

        test "call returns success result with data" do
          result = @calculator.call

          assert result.success?, "Expected success but got errors: #{result.errors}"
          assert_not_nil result.data
          assert_empty result.errors
          assert_instance_of Array, result.data
        end

        test "call creates ranked items in database" do
          # Clear any existing ranked items first
          @ranking_configuration.ranked_items.destroy_all

          # Count unique items across all lists to know how many ranked items to expect
          list_ids = @ranking_configuration.ranked_lists.pluck(:list_id)
          unique_item_count = ListItem.joins(:list)
            .where(lists: {id: list_ids})
            .where.not(listable_id: nil)
            .distinct
            .count(:listable_id)

          @calculator.call
          @ranking_configuration.reload

          # Should create ranked items for all unique items
          assert_equal unique_item_count, @ranking_configuration.ranked_items.count
          assert @ranking_configuration.ranked_items.any?, "Should have created ranked items"
        end

        test "call calculates correct rankings based on weights and positions" do
          @calculator.call

          ranked_items = @ranking_configuration.ranked_items.order(:rank)

          # Verify we have ranked items
          assert ranked_items.any?, "Should have created ranked items"

          # Verify ranking order (higher scores should have lower rank numbers)
          scores = ranked_items.pluck(:score)
          assert_equal scores.sort.reverse, scores, "Scores should be in descending order"

          # Verify ranks are sequential starting from 1
          ranks = ranked_items.pluck(:rank)
          expected_ranks = (1..ranks.length).to_a
          assert_equal expected_ranks, ranks, "Ranks should be sequential starting from 1"
        end

        test "call handles penalty calculations when enabled" do
          # Ensure penalty calculation is enabled
          @ranking_configuration.update!(apply_list_dates_penalty: true)

          result = @calculator.call

          assert result.success?
          # Should still create ranked items even with penalties
          assert @ranking_configuration.ranked_items.any?
        end

        test "call handles penalty calculations when disabled" do
          # Disable penalty calculation
          @ranking_configuration.update!(apply_list_dates_penalty: false)

          result = @calculator.call

          assert result.success?
          assert @ranking_configuration.ranked_items.any?
        end

        test "call updates existing ranked items with upsert" do
          # First calculation
          @calculator.call
          @ranking_configuration.reload
          initial_count = @ranking_configuration.ranked_items.count
          initial_created_at = @ranking_configuration.ranked_items.first.created_at

          # Second calculation should update, not duplicate
          @calculator.call
          @ranking_configuration.reload

          assert_equal initial_count, @ranking_configuration.ranked_items.count
          # created_at should remain the same (upsert preserves it)
          assert_equal initial_created_at, @ranking_configuration.ranked_items.first.created_at
        end

        test "call handles albums with different release years" do
          result = @calculator.call

          assert result.success?

          # Verify that albums with different release years are handled
          ranked_items = @ranking_configuration.ranked_items.includes(:item)
          release_years = ranked_items.map { |ri| ri.item.release_year }.compact.uniq

          assert release_years.length > 1, "Should handle albums from different years"
        end

        test "call only includes active lists" do
          # Create an inactive list
          inactive_list = lists(:music_albums_list)
          inactive_list.update!(status: :unapproved)

          result = @calculator.call

          assert result.success?
          # Should still work with remaining active lists
          assert @ranking_configuration.ranked_items.any?
        end

        test "call respects list weights in scoring" do
          result = @calculator.call

          assert result.success?

          # Get the album that appears in the highest weighted list (Rolling Stone - weight 20)
          rolling_stone_top_album = list_items(:rolling_stone_item_1).listable
          rolling_stone_ranked_item = @ranking_configuration.ranked_items.find_by(item: rolling_stone_top_album)

          # Should have a good score due to high weight and top position
          assert rolling_stone_ranked_item.present?
          assert rolling_stone_ranked_item.score > 0
        end

        test "call handles empty result gracefully" do
          # Remove all ranked lists to simulate empty scenario
          @ranking_configuration.ranked_lists.destroy_all

          result = @calculator.call

          assert result.success?
          assert_equal [], result.data
          assert_empty @ranking_configuration.ranked_items
        end

        test "call returns error result on exception" do
          # Stub to cause an exception
          @calculator.stubs(:prepare_lists).raises(StandardError, "Test error")

          result = @calculator.call

          assert_not result.success?
          assert_nil result.data
          assert_includes result.errors.first, "Test error"
        end

        # Integration test with actual weighted_list_rank gem
        test "integrates correctly with weighted_list_rank gem" do
          result = @calculator.call

          assert result.success?

          # Verify the data structure returned by weighted_list_rank
          result.data.each do |ranking|
            assert ranking.key?(:id), "Should have :id key"
            assert ranking.key?(:total_score), "Should have :total_score key"
            assert ranking.key?(:score_details), "Should have :score_details key"

            assert_instance_of Integer, ranking[:id]
            assert ranking[:total_score].is_a?(Numeric), "total_score should be numeric"
            assert_instance_of Array, ranking[:score_details]
          end
        end

        # Test configuration parameter effects
        test "different exponents affect ranking calculations" do
          # Test with default exponent
          @ranking_configuration.update!(exponent: 3.0)
          @calculator.call
          @ranking_configuration.reload
          scores1 = @ranking_configuration.ranked_items.pluck(:score).sort.reverse

          # Clear and test with different exponent
          @ranking_configuration.ranked_items.destroy_all
          @ranking_configuration.update!(exponent: 2.0)
          @calculator.call
          @ranking_configuration.reload
          scores2 = @ranking_configuration.ranked_items.pluck(:score).sort.reverse

          # Scores should be different with different exponents
          assert_not_equal scores1, scores2, "Different exponents should produce different scores"
        end

        test "different bonus pool percentages affect rankings" do
          # Test with default bonus pool
          @ranking_configuration.update!(bonus_pool_percentage: 3.0)
          @calculator.call
          @ranking_configuration.reload
          scores1 = @ranking_configuration.ranked_items.pluck(:score).sort.reverse

          # Clear and test with different bonus pool
          @ranking_configuration.ranked_items.destroy_all
          @ranking_configuration.update!(bonus_pool_percentage: 10.0)
          @calculator.call
          @ranking_configuration.reload
          scores2 = @ranking_configuration.ranked_items.pluck(:score).sort.reverse

          # Scores should be different with different bonus pools
          assert_not_equal scores1, scores2, "Different bonus pools should produce different scores"
        end
      end
    end
  end
end
