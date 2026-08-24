require "test_helper"

module Actions
  module Admin
    module Games
      class MergeGameTest < ActiveSupport::TestCase
        def setup
          @user = users(:admin_user)
          @target = games_games(:breath_of_the_wild)
          @source = games_games(:half_life_2)

          RankedItem.where(item: @source).destroy_all
          RankedItem.where(item: @target).destroy_all
        end

        def call(fields)
          Actions::Admin::Games::MergeGame.call(
            user: @user, models: [@target], fields: fields
          )
        end

        test "is destructive" do
          assert Actions::Admin::Games::MergeGame.destructive?
        end

        test "merges and reports success" do
          result = call({source_game_id: @source.id.to_s, confirm_merge: "1"})

          assert result.success?, result.message
          assert_match(/Half-Life 2/, result.message)
          assert_not ::Games::Game.exists?(@source.id)
        end

        test "reports a warning, not a plain success, when the post-commit follow-up fails" do
          ::Games::Game::Merger.any_instance.stubs(:reindex_target_game)
            .raises(StandardError.new("opensearch down"))

          result = call({source_game_id: @source.id.to_s, confirm_merge: "1"})

          assert result.warning?, result.message
          assert_not result.success?, "a warning must not also report as a plain success"
          assert_match(/Half-Life 2/, result.message)
          assert_match(/source game has been deleted/, result.message)
          assert_match(/could not be scheduled/, result.message)
          assert_match(/opensearch down/, result.message)
          assert_not ::Games::Game.exists?(@source.id), "the merge itself must still have committed"
        end

        test "requires a source game id" do
          result = call({confirm_merge: "1"})

          assert result.error?
          assert_equal "Please select a game to merge.", result.message
          assert ::Games::Game.exists?(@source.id)
        end

        test "requires the confirmation checkbox" do
          result = call({source_game_id: @source.id.to_s})

          assert result.error?
          assert_match(/confirm/i, result.message)
          assert ::Games::Game.exists?(@source.id)
        end

        test "reports a missing source game" do
          result = call({source_game_id: "999999", confirm_merge: "1"})

          assert result.error?
          assert_equal "Game with ID 999999 not found.", result.message
        end

        test "refuses to merge a game with itself" do
          result = call({source_game_id: @target.id.to_s, confirm_merge: "1"})

          assert result.error?
          assert_equal "Cannot merge a game with itself. Please select a different game.", result.message
          assert ::Games::Game.exists?(@target.id)
        end

        test "refuses to act on more than one game" do
          result = Actions::Admin::Games::MergeGame.call(
            user: @user,
            models: [@target, @source],
            fields: {source_game_id: @source.id.to_s, confirm_merge: "1"}
          )

          assert result.error?
          assert_match(/single game/, result.message)
        end

        test "surfaces merger failures" do
          ::Games::Game::Merger.any_instance.stubs(:call).returns(
            ::Games::Game::Merger::Result.new(success?: false, data: nil, errors: ["nope"])
          )

          result = call({source_game_id: @source.id.to_s, confirm_merge: "1"})

          assert result.error?
          assert_match(/nope/, result.message)
        end
      end
    end
  end
end
