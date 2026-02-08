require "test_helper"

module Games
  class GameTest < ActiveSupport::TestCase
    def setup
      @botw = games_games(:breath_of_the_wild)
      @re4 = games_games(:resident_evil_4)
      @re4_remake = games_games(:resident_evil_4_remake)
      @hl2 = games_games(:half_life_2)
      @totk = games_games(:tears_of_the_kingdom)
    end

    # Validations
    test "should be valid with valid attributes" do
      assert @botw.valid?
    end

    test "should require title" do
      @botw.title = nil
      assert_not @botw.valid?
      assert_includes @botw.errors[:title], "can't be blank"
    end

    test "should require game_type" do
      @botw.game_type = nil
      assert_not @botw.valid?
      assert_includes @botw.errors[:game_type], "can't be blank"
    end

    test "should allow nil release_year" do
      @botw.release_year = nil
      assert @botw.valid?
    end

    test "should require valid release_year if present" do
      @botw.release_year = 2017
      assert @botw.valid?
      @botw.release_year = 1960
      assert_not @botw.valid?
      assert_includes @botw.errors[:release_year], "must be greater than 1970"
      @botw.release_year = Date.current.year + 10
      assert_not @botw.valid?
    end

    test "should not allow parent_game to reference itself" do
      @botw.parent_game = @botw
      assert_not @botw.valid?
      assert_includes @botw.errors[:parent_game], "cannot reference itself"
    end

    test "should not allow parent_game on main_game type" do
      @botw.parent_game = @re4
      assert_not @botw.valid?
      assert_includes @botw.errors[:parent_game], "cannot be set for main games"
    end

    test "should allow parent_game on remake type" do
      assert @re4_remake.valid?
      assert_equal @re4, @re4_remake.parent_game
    end

    # Quote Normalization
    test "should normalize smart quotes in title" do
      game = Games::Game.create!(title: "\u201CThe Last of Us\u201D")
      assert_equal "\"The Last of Us\"", game.title
    end

    # Enums
    test "should define game_type enum" do
      assert Games::Game.game_types.key?("main_game")
      assert Games::Game.game_types.key?("remake")
      assert Games::Game.game_types.key?("remaster")
      assert Games::Game.game_types.key?("expansion")
      assert Games::Game.game_types.key?("dlc")
    end

    test "enum predicates work" do
      assert @botw.main_game?
      assert @re4_remake.remake?
    end

    # FriendlyId
    test "should find by slug" do
      found = Games::Game.friendly.find(@botw.slug)
      assert_equal @botw, found
    end

    # Associations
    test "should belong to series" do
      assert_equal games_series(:zelda), @botw.series
    end

    test "should have optional series" do
      assert_nil @hl2.series
      assert @hl2.valid?
    end

    test "should belong to parent_game" do
      assert_equal @re4, @re4_remake.parent_game
    end

    test "should have child_games" do
      assert_includes @re4.child_games, @re4_remake
    end

    test "should have companies through game_companies" do
      assert_includes @botw.companies, games_companies(:nintendo)
    end

    test "should have platforms through game_platforms" do
      assert_includes @re4_remake.platforms, games_platforms(:ps5)
      assert_includes @re4_remake.platforms, games_platforms(:pc)
    end

    # Scopes - Type filtering
    test "main_games scope" do
      main = Games::Game.main_games
      assert_includes main, @botw
      assert_includes main, @re4
      assert_not_includes main, @re4_remake
    end

    test "remakes scope" do
      remakes = Games::Game.remakes
      assert_includes remakes, @re4_remake
      assert_not_includes remakes, @re4
    end

    test "standalone scope includes main_game, remake, and remaster" do
      standalone = Games::Game.standalone
      assert_includes standalone, @botw
      assert_includes standalone, @re4_remake
    end

    # Scopes - Year filtering
    test "released_in scope" do
      games_2017 = Games::Game.released_in(2017)
      assert_includes games_2017, @botw
      assert_not_includes games_2017, @re4
    end

    test "released_in_range scope" do
      games_2000s = Games::Game.released_in_range(2000, 2010)
      assert_includes games_2000s, @re4
      assert_includes games_2000s, @hl2
      assert_not_includes games_2000s, @botw
    end

    test "released_before scope" do
      games_before_2010 = Games::Game.released_before(2010)
      assert_includes games_before_2010, @re4
      assert_includes games_before_2010, @hl2
      assert_not_includes games_before_2010, @botw
    end

    test "released_after scope" do
      games_after_2020 = Games::Game.released_after(2020)
      assert_includes games_after_2020, @re4_remake
      assert_includes games_after_2020, @totk
      assert_not_includes games_after_2020, @botw
    end

    # Scopes - Company filtering
    test "by_developer scope" do
      nintendo_games = Games::Game.by_developer(games_companies(:nintendo).id)
      assert_includes nintendo_games, @botw
      assert_includes nintendo_games, @totk
      assert_not_includes nintendo_games, @hl2
    end

    test "by_publisher scope" do
      capcom_published = Games::Game.by_publisher(games_companies(:capcom).id)
      assert_includes capcom_published, @re4
      assert_includes capcom_published, @re4_remake
      assert_not_includes capcom_published, @botw
    end

    # Scopes - Platform filtering
    test "on_platform scope" do
      pc_games = Games::Game.on_platform(games_platforms(:pc).id)
      assert_includes pc_games, @re4_remake
      assert_includes pc_games, @hl2
      assert_not_includes pc_games, @botw
    end

    test "on_platform_family scope filters by family" do
      playstation_games = Games::Game.on_platform_family(:playstation)
      assert_includes playstation_games, @re4_remake
      assert_not_includes playstation_games, @botw
      assert_not_includes playstation_games, @hl2
    end

    test "on_platform_family does not return duplicates for multi-platform games" do
      # RE4 Remake is on PS5 and PS4 (both playstation family)
      playstation_games = Games::Game.on_platform_family(:playstation)
      assert_equal 1, playstation_games.where(id: @re4_remake.id).count
    end

    test "on_platform does not return duplicates" do
      pc_games = Games::Game.on_platform(games_platforms(:pc).id)
      assert_equal 1, pc_games.where(id: @hl2.id).count
    end

    test "by_developer does not return duplicates" do
      nintendo_games = Games::Game.by_developer(games_companies(:nintendo).id)
      assert_equal 1, nintendo_games.where(id: @botw.id).count
    end

    # Scopes - Series
    test "in_series scope" do
      zelda_games = Games::Game.in_series(games_series(:zelda).id)
      assert_includes zelda_games, @botw
      assert_includes zelda_games, @totk
      assert_not_includes zelda_games, @hl2
    end

    # Helper methods - Companies
    test "developers returns only developer companies" do
      devs = @botw.developers
      assert_includes devs, games_companies(:nintendo)
    end

    test "publishers returns only publisher companies" do
      pubs = @re4.publishers
      assert_includes pubs, games_companies(:capcom)
    end

    # Helper methods - Relationships
    test "related_games_in_series returns other games in the series" do
      related = @botw.related_games_in_series
      assert_includes related, @totk
      assert_not_includes related, @botw
    end

    test "related_games_in_series returns none when no series" do
      assert_equal Games::Game.none, @hl2.related_games_in_series
    end

    test "original_game returns parent for remakes" do
      assert_equal @re4, @re4_remake.original_game
    end

    test "original_game returns nil for main games" do
      assert_nil @botw.original_game
    end

    # Dependent destroy
    test "destroying a game nullifies child parent_game_id" do
      @re4.destroy!
      assert_nil @re4_remake.reload.parent_game_id
    end

    test "destroying a game removes game_companies" do
      assert_difference "Games::GameCompany.count", -1 do
        @hl2.destroy!
      end
    end

    test "destroying a game removes game_platforms" do
      platform_count = @re4_remake.game_platforms.count
      assert platform_count > 0
      assert_difference "Games::GamePlatform.count", -platform_count do
        @re4_remake.destroy!
      end
    end

    # SearchIndexable concern
    test "should create search index request on create" do
      assert_difference "SearchIndexRequest.count", 1 do
        Games::Game.create!(title: "Test Game")
      end

      request = SearchIndexRequest.last
      assert_equal "Games::Game", request.parent_type
      assert request.index_item?
    end

    test "should create search index request on update" do
      assert_difference "SearchIndexRequest.count", 1 do
        @botw.update!(title: "Updated Title")
      end

      request = SearchIndexRequest.last
      assert_equal @botw, request.parent
      assert request.index_item?
    end

    test "should create search index request on destroy" do
      assert_difference "SearchIndexRequest.count", 1 do
        @hl2.destroy!
      end

      request = SearchIndexRequest.last
      assert_equal "Games::Game", request.parent_type
      assert request.unindex_item?
    end
  end
end
