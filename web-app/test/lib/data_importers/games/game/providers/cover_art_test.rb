# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Games
    module Game
      module Providers
        class CoverArtTest < ActiveSupport::TestCase
          def setup
            @provider = CoverArt.new
            @game = games_games(:breath_of_the_wild)
            # Add IGDB identifier
            @game.identifiers.create!(
              identifier_type: :games_igdb_id,
              value: "7346"
            )
          end

          test "populate queues CoverArtDownloadJob for persisted game with IGDB identifier" do
            ::Games::CoverArtDownloadJob.expects(:perform_async).with(@game.id)

            result = @provider.populate(@game, query: nil)

            assert result.success?
            assert_includes result.data_populated, :cover_art_queued
          end

          test "populate fails when game is not persisted" do
            new_game = ::Games::Game.new(title: "Test")

            result = @provider.populate(new_game, query: nil)

            refute result.success?
            assert_includes result.errors, "Game must be persisted"
          end

          test "populate fails when game has no IGDB identifier" do
            game_without_identifier = games_games(:half_life_2)

            result = @provider.populate(game_without_identifier, query: nil)

            refute result.success?
            assert_includes result.errors, "Game must have IGDB identifier"
          end
        end
      end
    end
  end
end
