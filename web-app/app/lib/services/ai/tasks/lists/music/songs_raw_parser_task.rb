# frozen_string_literal: true

module Services
  module Ai
    module Tasks
      module Lists
        module Music
          class SongsRawParserTask < BaseRawParserTask
            private

            def media_type = "songs"

            def extraction_fields
              [
                "Rank (if present, can be null)",
                "Song title",
                "Artist name(s)",
                "Album name (if present, can be null)",
                "Release year (if present, can be null)"
              ]
            end

            def media_specific_instructions
              <<~INSTRUCTIONS
                Understanding song information:
                - Songs may be listed with or without album information
                - Featured artists should be included in the artists array
                - Duration may be present but is not required for extraction
                - Some songs may have multiple versions (live, remix, etc.) - note if present
              INSTRUCTIONS
            end

            def extraction_examples
              <<~EXAMPLES
                Examples:
                For "1. Bohemian Rhapsody - Queen (A Night at the Opera, 1975)":
                - Rank: 1
                - Title: "Bohemian Rhapsody"
                - Artists: ["Queen"]
                - Album: "A Night at the Opera"
                - Release Year: 1975

                For "Imagine by John Lennon":
                - Rank: null
                - Title: "Imagine"
                - Artists: ["John Lennon"]
                - Album: null
                - Release Year: null
              EXAMPLES
            end

            def response_schema
              ResponseSchema
            end

            class ResponseSchema < RubyLLM::Schema
              def self.name
                "Songs"
              end

              array :songs do
                object do
                  integer :rank, required: false, description: "Rank position in the list"
                  string :title, required: true, description: "Song title"
                  array :artists, of: :string, description: "Artist name(s)"
                  string :album, required: false, description: "Album name if present"
                  integer :release_year, required: false, description: "Year the song was released"
                end
              end
            end
          end
        end
      end
    end
  end
end
