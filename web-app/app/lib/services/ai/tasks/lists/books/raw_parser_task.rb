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

            class Book < OpenAI::BaseModel
              required :rank, Integer, nil?: true, doc: "Rank position in the list"
              required :title, String, doc: "Book title"
              required :authors, OpenAI::ArrayOf[String], doc: "Author name(s)"
              required :publication_year, Integer, nil?: true, doc: "Year the book was published"
            end

            class ResponseSchema < OpenAI::BaseModel
              required :books, OpenAI::ArrayOf[Book]
            end
          end
        end
      end
    end
  end
end
