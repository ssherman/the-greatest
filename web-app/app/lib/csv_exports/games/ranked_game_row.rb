# frozen_string_literal: true

module CsvExports
  module Games
    class RankedGameRow
      URL_HELPERS = Rails.application.routes.url_helpers

      HEADERS = ["Rank", "Score", "ID", "Title", "Year", "Platforms", "Companies", "Genres", "URL"].freeze

      def self.preloads
        []
      end

      def self.context(game_ids)
        {
          platforms: Aggregate.names(::Games::GamePlatform.joins(:platform).where(game_id: game_ids),
            group_by: "games_game_platforms.game_id", name: "games_platforms.name", order: "games_platforms.name"),
          companies: Aggregate.names(::Games::GameCompany.joins(:company).where(game_id: game_ids),
            group_by: "games_game_companies.game_id", name: "games_companies.name", order: "games_companies.name"),
          genres: Aggregate.names(
            ::CategoryItem.joins(:category).where(item_type: "Games::Game", item_id: game_ids,
              categories: {type: "Games::Category", deleted: false, category_type: ::Category.category_types[:genre]}),
            group_by: "category_items.item_id", name: "categories.name", order: "categories.name"
          )
        }
      end

      def self.row(ranked_item, ctx)
        game = ranked_item.item
        [
          ranked_item.rank,
          Cells.score(ranked_item.score),
          game.id,
          game.title,
          game.release_year,
          ctx[:platforms][game.id],
          ctx[:companies][game.id],
          ctx[:genres][game.id],
          "#{Api::Host.base_url(:games)}#{URL_HELPERS.game_path(game)}"
        ]
      end
    end
  end
end
