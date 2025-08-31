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

            class ResponseSchema < RubyLLM::Schema
              def self.name
                "Movies"
              end

              array :movies do
                object do
                  integer :rank, required: false, description: "Rank position in the list"
                  string :title, required: true, description: "Movie title"
                  array :directors, of: :string, description: "Director name(s)"
                  integer :release_year, required: false, description: "Year the movie was released"
                end
              end
            end
          end
        end
      end
    end
  end
end
