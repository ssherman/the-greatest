# frozen_string_literal: true

module Services
  module Games
    class AmazonProductService < ::Services::Amazon::BaseProductService
      def self.call(game:)
        new(game).call
      end

      private

      alias_method :game, :record

      def validation_errors
        return ["Game title required"] if game.title.blank?
        []
      end

      # Every category, not just video games: guides, soundtracks, art books and
      # collectibles are all legitimate matches for a game.
      def search_param_sets
        [{keywords: game.title, search_index: "All"}]
      end

      def match_task_class
        ::Services::Ai::Tasks::Games::AmazonGameMatchTask
      end

      # No after_persist override: games take cover art from IGDB, never Amazon.
      def persist_match(match, product)
        upsert_external_link(
          parent: game,
          product: product,
          metadata: {product_type: match[:product_type], platform: match[:platform]}
        )
      end
    end
  end
end
