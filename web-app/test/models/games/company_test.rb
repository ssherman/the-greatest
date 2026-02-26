# == Schema Information
#
# Table name: games_companies
#
#  id           :bigint           not null, primary key
#  country      :string(2)
#  description  :text
#  name         :string           not null
#  slug         :string           not null
#  year_founded :integer
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#
# Indexes
#
#  index_games_companies_on_name  (name)
#  index_games_companies_on_slug  (slug) UNIQUE
#
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

    test "developed_games excludes games where company is publisher only" do
      # Add capcom as publisher-only on another game
      Games::GameCompany.create!(game: games_games(:half_life_2), company: @capcom, developer: false, publisher: true)

      developed = @capcom.developed_games
      assert_not_includes developed, games_games(:half_life_2)
    end

    test "developed_games does not return duplicates" do
      developed = @capcom.developed_games
      assert_equal developed.size, developed.distinct.size
    end

    test "published_games returns games where company is publisher" do
      published = @valve.published_games
      assert_includes published, games_games(:half_life_2)
      assert_not_includes published, games_games(:breath_of_the_wild)
    end

    test "published_games does not return duplicates" do
      published = @valve.published_games
      assert_equal published.size, published.distinct.size
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
