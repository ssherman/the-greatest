# == Schema Information
#
# Table name: games_series
#
#  id          :bigint           not null, primary key
#  description :text
#  name        :string           not null
#  slug        :string           not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#
# Indexes
#
#  index_games_series_on_name  (name)
#  index_games_series_on_slug  (slug) UNIQUE
#
require "test_helper"

module Games
  class SeriesTest < ActiveSupport::TestCase
    def setup
      @zelda = games_series(:zelda)
      @re = games_series(:resident_evil)
    end

    # Validations
    test "should be valid with valid attributes" do
      assert @zelda.valid?
    end

    test "should require name" do
      @zelda.name = nil
      assert_not @zelda.valid?
      assert_includes @zelda.errors[:name], "can't be blank"
    end

    # Quote Normalization
    test "should normalize smart quotes in name" do
      series = Games::Series.create!(name: "\u201CAssassin\u2019s Creed\u201D")
      assert_equal "\"Assassin's Creed\"", series.name
    end

    # FriendlyId
    test "should find by slug" do
      found = Games::Series.friendly.find(@zelda.slug)
      assert_equal @zelda, found
    end

    # Associations
    test "should have games" do
      assert_includes @zelda.games, games_games(:breath_of_the_wild)
      assert_includes @zelda.games, games_games(:tears_of_the_kingdom)
    end

    # Dependent nullify
    test "destroying a series nullifies series_id on games" do
      game = games_games(:breath_of_the_wild)
      assert_equal @zelda, game.series
      @zelda.destroy!
      assert_nil game.reload.series_id
    end
  end
end
