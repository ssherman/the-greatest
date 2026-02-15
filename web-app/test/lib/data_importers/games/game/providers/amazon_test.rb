# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Games
    module Game
      module Providers
        class AmazonTest < ActiveSupport::TestCase
          def setup
            @provider = Amazon.new
            @game = games_games(:breath_of_the_wild)
          end

          test "populate queues AmazonProductEnrichmentJob for persisted game with title" do
            ::Games::AmazonProductEnrichmentJob.expects(:perform_async).with(@game.id)

            result = @provider.populate(@game, query: nil)

            assert result.success?
            assert_includes result.data_populated, :amazon_enrichment_queued
          end

          test "populate fails when game is not persisted" do
            new_game = ::Games::Game.new(title: "Test")

            result = @provider.populate(new_game, query: nil)

            refute result.success?
            assert_includes result.errors, "Game must be persisted before queuing Amazon enrichment job"
          end

          test "populate fails when game has no title" do
            game_without_title = ::Games::Game.new
            game_without_title.stubs(:persisted?).returns(true)
            game_without_title.title = ""

            result = @provider.populate(game_without_title, query: nil)

            refute result.success?
            assert_includes result.errors, "Game title required for Amazon search"
          end
        end
      end
    end
  end
end
