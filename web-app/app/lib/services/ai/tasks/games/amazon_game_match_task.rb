# frozen_string_literal: true

module Services
  module Ai
    module Tasks
      module Games
        class AmazonGameMatchTask < ::Services::Ai::Tasks::AmazonProductMatchTask
          private

          def domain_name
            "game"
          end

          def item_description
            lines = ["- Title: #{parent.title}"]
            platforms = parent.platforms.map(&:name).join(", ")
            lines << "- Platforms: #{platforms}" if platforms.present?
            lines << "- Release Year: #{parent.release_year}" if parent.release_year.present?
            lines.join("\n")
          end

          def match_criteria
            <<~CRITERIA.strip
              - The game itself (any edition, platform, format)
              - Strategy guides and walkthroughs for the game
              - Art books and "making of" books about the game
              - Official soundtracks
              - Collectibles and figures (officially licensed)
              - DLC, season passes, expansion packs
              - Remasters, remakes, definitive editions
              - Bundles that include the game
            CRITERIA
          end

          def non_match_criteria
            <<~CRITERIA.strip
              - Completely unrelated products
              - Products for different games with similar names
              - Generic gaming accessories not specific to this game
              - Fan-made or unofficial merchandise
              - Products that just mention the game in reviews/description
            CRITERIA
          end

          # Internal schema class with product_type for game-related products
          class MatchResult < OpenAI::BaseModel
            required :asin, String, doc: "Amazon ASIN of the matching product"
            required :title, String, doc: "Product title from Amazon"
            required :product_type, String, doc: "Type: game, guide, artbook, soundtrack, collectible, dlc, bundle, other"
            required :platform, String, nil?: true, doc: "Platform if applicable (e.g., Nintendo Switch, PlayStation 5)"
            required :explanation, String, doc: "Brief explanation of why this is a match"
          end

          class ResponseSchema < OpenAI::BaseModel
            required :matching_results, OpenAI::ArrayOf[MatchResult]
          end
        end
      end
    end
  end
end
