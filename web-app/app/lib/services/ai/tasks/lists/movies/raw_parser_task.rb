# frozen_string_literal: true

module Services
  module Ai
    module Tasks
      module Lists
        module Movies
          class RawParserTask < BaseRawParserTask
            private

            def media_type = "movies"

            def extraction_fields
              [
                "Rank (if present, can be null)",
                "Movie title",
                "Director name(s)",
                "Release year (if present, can be null)"
              ]
            end

            def media_specific_instructions
              <<~INSTRUCTIONS
                Understanding movie information:
                - Movies may have multiple directors
                - Release year may be mentioned in parentheses or as separate text
                - Some lists may include runtime or genre - ignore these for now
                - Remove studio information from titles
              INSTRUCTIONS
            end

            def extraction_examples
              <<~EXAMPLES
                Examples:
                For "1. Citizen Kane - Orson Welles (1941)":
                - Rank: 1
                - Title: "Citizen Kane"
                - Directors: ["Orson Welles"]
                - Release Year: 1941

                For "The Godfather directed by Francis Ford Coppola":
                - Rank: null
                - Title: "The Godfather"
                - Directors: ["Francis Ford Coppola"]
                - Release Year: null
              EXAMPLES
            end

            def response_schema
              ResponseSchema
            end

            class Movie < OpenAI::BaseModel
              required :rank, Integer, nil?: true, doc: "Rank position in the list"
              required :title, String, doc: "Movie title"
              required :directors, OpenAI::ArrayOf[String], doc: "Director name(s)"
              required :release_year, Integer, nil?: true, doc: "Year the movie was released"
            end

            class ResponseSchema < OpenAI::BaseModel
              required :movies, OpenAI::ArrayOf[Movie]
            end
          end
        end
      end
    end
  end
end
