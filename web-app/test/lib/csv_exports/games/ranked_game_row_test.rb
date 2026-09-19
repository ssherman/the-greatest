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
        assert_equal "#{Api::Host.base_url(:games)}/game/the-legend-of-zelda-breath-of-the-wild", row[8]
      end
    end
  end
end
