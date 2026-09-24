# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Games
    module Game
      class FinderTest < ActiveSupport::TestCase
        def setup
          @finder = Finder.new
          @zelda = games_games(:breath_of_the_wild)
        end

        test "summarize carries the game's companies and release year for the audit pages" do
          summary = @finder.summarize(@zelda)

          assert_equal "The Legend of Zelda: Breath of the Wild", summary[:title]
          assert_equal ["Nintendo"], summary[:creators]
          assert_equal 2017, summary[:year]
        end

        test "call finds existing game by IGDB identifier" do
          # Create IGDB identifier for Zelda
          @zelda.identifiers.create!(
            identifier_type: :games_igdb_id,
            value: "7346"
          )

          query = ImportQuery.new(igdb_id: 7346)
          result = @finder.call(query: query)

          assert_equal @zelda, result.record
        end

        test "call returns nil when no identifier matches" do
          query = ImportQuery.new(igdb_id: 99999)
          result = @finder.call(query: query)

          assert_nil result.record
        end

        test "call returns nil when igdb_id is blank" do
          query = ImportQuery.new(igdb_id: nil)

          # Bypass validation for this test
          query.stubs(:valid?).returns(true)

          result = @finder.call(query: query)

          assert_nil result.record
        end

        test "records a decision on every call" do
          query = ImportQuery.new(igdb_id: 999999)
          query.stubs(:valid?).returns(true)

          assert_difference("MatchDecision.count", 1) { @finder.call(query: query) }
          assert_equal "DataImporters::Games::Game::Finder", MatchDecision.last.finder
        end
      end
    end
  end
end
