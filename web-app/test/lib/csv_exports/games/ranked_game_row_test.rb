# frozen_string_literal: true

require "test_helper"

module CsvExports
  module Games
    class RankedGameRowTest < ActiveSupport::TestCase
      test "headers" do
        assert_equal ["Rank", "Score", "ID", "Title", "Year", "Platforms", "Companies", "Genres", "URL"],
          RankedGameRow::HEADERS
      end

      test "a row" do
        ranked = ranked_items(:games_ranked_botw)
        game = games_games(:breath_of_the_wild)
        ctx = RankedGameRow.context([game.id])

        row = RankedGameRow.row(ranked, ctx)

        assert_equal [1, "98.50", game.id, "The Legend of Zelda: Breath of the Wild", 2017], row[0..4]
        assert_equal "Nintendo Switch", row[5]
        assert_equal "Nintendo", row[6]
        assert_nil row[7]
        assert_equal "#{Api::Host.base_url(:games)}/game/the-legend-of-zelda-breath-of-the-wild", row[8]
      end

      test "genres come from the game's non-deleted genre categories" do
        ranked = ranked_items(:games_ranked_totk)
        game = games_games(:tears_of_the_kingdom)

        row = RankedGameRow.row(ranked, RankedGameRow.context([game.id]))

        assert_equal "Action", row[7]
      end

      test "several platforms and companies are joined alphabetically" do
        game = games_games(:resident_evil_4_remake)
        ranked = RankedItem.create!(item: game, ranking_configuration: ranking_configurations(:games_global), rank: 9, score: 80)
        ::Games::GameCompany.create!(game: game, company: games_companies(:valve), publisher: true)

        row = RankedGameRow.row(ranked, RankedGameRow.context([game.id]))

        assert_equal "PC, PlayStation 4, PlayStation 5, Xbox Series X/S", row[5]
        assert_equal "Capcom, Valve", row[6]
      end
    end
  end
end
