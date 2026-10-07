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
                "Book title, without its subtitle",
                "Subtitle (if present, can be null)",
                "Author name(s)",
                "Publication year (if present, can be null)"
              ]
            end

            def media_specific_instructions
              <<~INSTRUCTIONS
                Understanding book information:
                - Books may have multiple authors
                - Publication year may be mentioned in parentheses or as separate text
                - A subtitle usually follows the title after a colon or a dash, or sits on its own line.
                  Put the main title in the title field and the subtitle in the subtitle field.
                  Never invent a subtitle; use null when there is none.
                - Remove publisher information from titles
              INSTRUCTIONS
            end

            def extraction_examples
              <<~EXAMPLES
                Examples:
                For "1. To Kill a Mockingbird - Harper Lee (1960)":
                - Rank: 1
                - Title: "To Kill a Mockingbird"
                - Subtitle: null
                - Authors: ["Harper Lee"]
                - Publication Year: 1960

                For "Sapiens: A Brief History of Humankind by Yuval Noah Harari":
                - Rank: null
                - Title: "Sapiens"
                - Subtitle: "A Brief History of Humankind"
                - Authors: ["Yuval Noah Harari"]
                - Publication Year: null
              EXAMPLES
            end

            def response_schema
              ResponseSchema
            end

            class Book < OpenAI::BaseModel
              required :rank, Integer, nil?: true, doc: "Rank position in the list"
              required :title, String, doc: "Book title, without its subtitle"
              required :subtitle, String, nil?: true, doc: "Subtitle split from the title, or null"
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
