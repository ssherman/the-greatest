# frozen_string_literal: true

module Services
  module Ai
    module Tasks
      module Lists
        module Books
          class RawParserTask < BaseRawParserTask
            private

            def media_type = "books"

            def extraction_fields
              [
                "Rank (if present, can be null)",
                "Book title",
                "Author name(s)",
                "Publication year (if present, can be null)"
              ]
            end

            def media_specific_instructions
              <<~INSTRUCTIONS
                Understanding book information:
                - Books may have multiple authors
                - Publication year may be mentioned in parentheses or as separate text
                - Some lists may include subtitles - include them in the title field
                - Remove publisher information from titles
              INSTRUCTIONS
            end

            def extraction_examples
              <<~EXAMPLES
                Examples:
                For "1. To Kill a Mockingbird - Harper Lee (1960)":
                - Rank: 1
                - Title: "To Kill a Mockingbird"
                - Authors: ["Harper Lee"]
                - Publication Year: 1960

                For "The Great Gatsby by F. Scott Fitzgerald":
                - Rank: null
                - Title: "The Great Gatsby"
                - Authors: ["F. Scott Fitzgerald"]
                - Publication Year: null
              EXAMPLES
            end

            def response_schema
              ResponseSchema
            end

            class ResponseSchema < RubyLLM::Schema
              def self.name
                "Books"
              end

              array :books do
                object do
                  integer :rank, required: false, description: "Rank position in the list"
                  string :title, required: true, description: "Book title"
                  array :authors, of: :string, description: "Author name(s)"
                  integer :publication_year, required: false, description: "Year the book was published"
                end
              end
            end
          end
        end
      end
    end
  end
end
