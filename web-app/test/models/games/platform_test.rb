require "test_helper"

module Games
  class PlatformTest < ActiveSupport::TestCase
    def setup
      @switch = games_platforms(:switch)
      @ps5 = games_platforms(:ps5)
      @pc = games_platforms(:pc)
    end

    # Validations
    test "should be valid with valid attributes" do
      assert @switch.valid?
    end

    test "should require name" do
      @switch.name = nil
      assert_not @switch.valid?
      assert_includes @switch.errors[:name], "can't be blank"
    end

    # Enums
    test "should define platform_family enum" do
      assert Games::Platform.platform_families.key?("playstation")
      assert Games::Platform.platform_families.key?("xbox")
      assert Games::Platform.platform_families.key?("nintendo")
      assert Games::Platform.platform_families.key?("pc")
      assert Games::Platform.platform_families.key?("mobile")
      assert Games::Platform.platform_families.key?("other")
    end

    test "enum predicates work" do
      assert @switch.nintendo?
      assert @ps5.playstation?
      assert @pc.pc?
    end

    # FriendlyId
    test "should find by slug" do
      found = Games::Platform.friendly.find(@switch.slug)
      assert_equal @switch, found
    end

    # Associations
    test "should have games through game_platforms" do
      assert_includes @switch.games, games_games(:breath_of_the_wild)
    end

    # Scopes
    test "by_family scope filters by platform family" do
      nintendo_platforms = Games::Platform.by_family(:nintendo)
      assert_includes nintendo_platforms, @switch
      assert_not_includes nintendo_platforms, @ps5
    end

    # Dependent destroy
    test "destroying a platform removes game_platforms" do
      gp_count = @switch.game_platforms.count
      assert gp_count > 0
      assert_difference "Games::GamePlatform.count", -gp_count do
        @switch.destroy!
      end
    end
  end
end
