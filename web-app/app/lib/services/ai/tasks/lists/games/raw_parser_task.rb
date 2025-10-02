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
                "Developer/Studio name(s)",
                "Release year (if present, can be null)"
              ]
            end

            def media_specific_instructions
              <<~INSTRUCTIONS
                Understanding game information:
                - Games may have multiple developers or studios
                - Release year may be mentioned in parentheses or as separate text
                - Some lists may include platform information - ignore for now
                - Remove publisher information from titles unless it's part of the actual title
              INSTRUCTIONS
            end

            def extraction_examples
              <<~EXAMPLES
                Examples:
                For "1. The Legend of Zelda: Breath of the Wild - Nintendo (2017)":
                - Rank: 1
                - Title: "The Legend of Zelda: Breath of the Wild"
                - Developers: ["Nintendo"]
                - Release Year: 2017

                For "Super Mario Bros. by Nintendo":
                - Rank: null
                - Title: "Super Mario Bros."
                - Developers: ["Nintendo"]
                - Release Year: null
              EXAMPLES
            end

            def response_schema
              ResponseSchema
            end

            class Game < OpenAI::BaseModel
              required :rank, Integer, nil?: true, doc: "Rank position in the list"
              required :title, String, doc: "Game title"
              required :developers, OpenAI::ArrayOf[String], doc: "Developer name(s)"
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
