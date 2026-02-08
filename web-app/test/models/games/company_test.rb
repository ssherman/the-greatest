require "test_helper"

module Games
  class CompanyTest < ActiveSupport::TestCase
    def setup
      @nintendo = games_companies(:nintendo)
      @capcom = games_companies(:capcom)
      @valve = games_companies(:valve)
    end

    # Validations
    test "should be valid with valid attributes" do
      assert @nintendo.valid?
    end

    test "should require name" do
      @nintendo.name = nil
      assert_not @nintendo.valid?
      assert_includes @nintendo.errors[:name], "can't be blank"
    end

    test "should allow blank country" do
      @nintendo.country = nil
      assert @nintendo.valid?
    end

    test "should require 2 character country if present" do
      @nintendo.country = "JP"
      assert @nintendo.valid?
      @nintendo.country = "JPN"
      assert_not @nintendo.valid?
      assert_includes @nintendo.errors[:country], "is the wrong length (should be 2 characters)"
    end

    # Quote Normalization
    test "should normalize smart quotes in name" do
      company = Games::Company.create!(name: "\u201CSome Studio\u201D")
      assert_equal "\"Some Studio\"", company.name
    end

    # FriendlyId
    test "should find by slug" do
      found = Games::Company.friendly.find(@nintendo.slug)
      assert_equal @nintendo, found
    end

    # Associations
    test "should have games through game_companies" do
      assert_includes @nintendo.games, games_games(:breath_of_the_wild)
    end

    # Scopes
    test "developers scope returns companies that have developed games" do
      devs = Games::Company.developers
      assert_includes devs, @nintendo
      assert_includes devs, @capcom
    end

    test "publishers scope returns companies that have published games" do
      pubs = Games::Company.publishers
      assert_includes pubs, @nintendo
    end

    # Helper methods
    test "developed_games returns games where company is developer" do
      developed = @capcom.developed_games
      assert_includes developed, games_games(:resident_evil_4)
      assert_includes developed, games_games(:resident_evil_4_remake)
      assert_not_includes developed, games_games(:breath_of_the_wild)
    end

    test "published_games returns games where company is publisher" do
      published = @valve.published_games
      assert_includes published, games_games(:half_life_2)
      assert_not_includes published, games_games(:breath_of_the_wild)
    end

    # Dependent destroy
    test "destroying a company removes game_companies" do
      gc_count = @valve.game_companies.count
      assert gc_count > 0
      assert_difference "Games::GameCompany.count", -gc_count do
        @valve.destroy!
      end
    end
  end
end
