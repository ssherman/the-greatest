require "test_helper"

module Games
  class GameCompanyTest < ActiveSupport::TestCase
    def setup
      @botw_nintendo = games_game_companies(:botw_nintendo_dev)
    end

    # Validations
    test "should be valid with valid attributes" do
      assert @botw_nintendo.valid?
    end

    test "should require at least one role" do
      gc = Games::GameCompany.new(
        game: games_games(:half_life_2),
        company: games_companies(:nintendo),
        developer: false,
        publisher: false
      )
      assert_not gc.valid?
      assert_includes gc.errors[:base], "must be either a developer or publisher (or both)"
    end

    test "should allow developer only" do
      gc = Games::GameCompany.new(
        game: games_games(:breath_of_the_wild),
        company: games_companies(:valve),
        developer: true,
        publisher: false
      )
      assert gc.valid?
    end

    test "should allow publisher only" do
      gc = Games::GameCompany.new(
        game: games_games(:breath_of_the_wild),
        company: games_companies(:valve),
        developer: false,
        publisher: true
      )
      assert gc.valid?
    end

    test "should allow both developer and publisher" do
      assert @botw_nintendo.developer?
      assert @botw_nintendo.publisher?
      assert @botw_nintendo.valid?
    end

    test "should enforce unique game-company pair" do
      duplicate = Games::GameCompany.new(
        game: @botw_nintendo.game,
        company: @botw_nintendo.company,
        developer: true
      )
      assert_not duplicate.valid?
      assert_includes duplicate.errors[:game_id], "has already been taken"
    end

    # Scopes
    test "developers scope returns records where developer is true" do
      devs = Games::GameCompany.developers
      assert devs.all?(&:developer?)
    end

    test "publishers scope returns records where publisher is true" do
      pubs = Games::GameCompany.publishers
      assert pubs.all?(&:publisher?)
    end
  end
end
