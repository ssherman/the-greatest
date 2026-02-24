# frozen_string_literal: true

module Services
  module Ai
    module Tasks
      module Lists
        module Games
          class RawParserTask < BaseRawParserTask
            private

            def media_type = "games"

            def extraction_fields
              [
                "Rank (if present, can be null)",
                "Game title",
                "Release year (if present, can be null)"
              ]
            end

            def media_specific_instructions
              <<~INSTRUCTIONS
                Understanding game information:
                - Release year may be mentioned in parentheses or as separate text
                - Some lists may include platform information - ignore for now
                - Remove developer/publisher names from titles unless they're part of the actual game title
              INSTRUCTIONS
            end

            def extraction_examples
              <<~EXAMPLES
                Examples:
                For "1. The Legend of Zelda: Breath of the Wild - Nintendo (2017)":
                - Rank: 1
                - Title: "The Legend of Zelda: Breath of the Wild"
                - Release Year: 2017

                For "Super Mario Bros. by Nintendo":
                - Rank: null
                - Title: "Super Mario Bros."
                - Release Year: null
              EXAMPLES
            end

            def response_schema
              ResponseSchema
            end

            class Game < OpenAI::BaseModel
              required :rank, Integer, nil?: true, doc: "Rank position in the list"
              required :title, String, doc: "Game title"
              required :release_year, Integer, nil?: true, doc: "Year the game was released"
            end

            class ResponseSchema < OpenAI::BaseModel
              required :games, OpenAI::ArrayOf[Game]
            end
          end
        end
      end
    end
  end
end
