# frozen_string_literal: true

module Services
  module Ai
    module Tasks
      module Lists
        module Music
          class AlbumsRawParserTask < BaseRawParserTask
            private

            def media_type = "albums"

            def extraction_fields
              [
                "Rank (if present, can be null)",
                "Album title",
                "Artist name(s)",
                "Release year (if present, can be null)"
              ]
            end

            def media_specific_instructions
              <<~INSTRUCTIONS
                Understanding album information:
                - Albums typically have a primary artist, but may have multiple artists
                - Release year may be mentioned in parentheses or as separate text
                - Album titles should not include artist names unless it's part of the actual title
              INSTRUCTIONS
            end

            def extraction_examples
              <<~EXAMPLES
                Examples:
                For "1. The Dark Side of the Moon - Pink Floyd (1973)":
                - Rank: 1
                - Title: "The Dark Side of the Moon"
                - Artists: ["Pink Floyd"]
                - Release Year: 1973

                For "Abbey Road by The Beatles":
                - Rank: null
                - Title: "Abbey Road"
                - Artists: ["The Beatles"]
                - Release Year: null
              EXAMPLES
            end

            def response_schema
              ResponseSchema
            end

            class ResponseSchema < RubyLLM::Schema
              def self.name
                "Albums"
              end

              array :albums do
                object do
                  integer :rank, required: false, description: "Rank position in the list"
                  string :title, required: true, description: "Album title"
                  array :artists, of: :string, description: "Artist name(s)"
                  integer :release_year, required: false, description: "Year the album was released"
                end
              end
            end
          end
        end
      end
    end
  end
end
