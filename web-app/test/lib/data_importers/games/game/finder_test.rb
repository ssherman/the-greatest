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

        test "call finds existing game by IGDB identifier" do
          # Create IGDB identifier for Zelda
          @zelda.identifiers.create!(
            identifier_type: :games_igdb_id,
            value: "7346"
          )

          query = ImportQuery.new(igdb_id: 7346)
          result = @finder.call(query: query)

          assert_equal @zelda, result
        end

        test "call returns nil when no identifier matches" do
          query = ImportQuery.new(igdb_id: 99999)
          result = @finder.call(query: query)

          assert_nil result
        end

        test "call returns nil when igdb_id is blank" do
          query = ImportQuery.new(igdb_id: nil)

          # Bypass validation for this test
          query.stubs(:valid?).returns(true)

          result = @finder.call(query: query)

          assert_nil result
        end
      end
    end
  end
end
