# == Schema Information
#
# Table name: games_game_platforms
#
#  id          :bigint           not null, primary key
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  game_id     :bigint           not null
#  platform_id :bigint           not null
#
# Indexes
#
#  index_games_game_platforms_on_game_and_platform  (game_id,platform_id) UNIQUE
#  index_games_game_platforms_on_game_id            (game_id)
#  index_games_game_platforms_on_platform_id        (platform_id)
#
# Foreign Keys
#
#  fk_rails_...  (game_id => games_games.id)
#  fk_rails_...  (platform_id => games_platforms.id)
#
require "test_helper"

module Games
  class GamePlatformTest < ActiveSupport::TestCase
    def setup
      @botw_switch = games_game_platforms(:botw_switch)
    end

    # Validations
    test "should be valid with valid attributes" do
      assert @botw_switch.valid?
    end

    test "should enforce unique game-platform pair" do
      duplicate = Games::GamePlatform.new(
        game: @botw_switch.game,
        platform: @botw_switch.platform
      )
      assert_not duplicate.valid?
      assert_includes duplicate.errors[:game_id], "has already been taken"
    end

    # Associations
    test "should belong to game" do
      assert_equal games_games(:breath_of_the_wild), @botw_switch.game
    end

    test "should belong to platform" do
      assert_equal games_platforms(:switch), @botw_switch.platform
    end
  end
end
