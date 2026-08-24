# frozen_string_literal: true

module Services
  module Ai
    module Tasks
      module Books
        class AmazonBookMatchTask < ::Services::Ai::Tasks::AmazonProductMatchTask
          private

          def domain_name
            "book"
          end

          def item_description
            lines = ["- Title: #{parent.title}"]
            lines << "- Subtitle: #{parent.subtitle}" if parent.subtitle.present?
            lines << "- Authors: #{parent.authors.map(&:name).join(", ")}"
            if parent.alternate_titles.present?
              lines << "- Alternate Titles: #{parent.alternate_titles.join(", ")}"
            end
            if parent.first_published_year.present?
              lines << "- First Published: #{parent.first_published_year}"
            end
            lines.join("\n")
          end

          def match_criteria
            <<~CRITERIA.strip
              - The titles represent the same literary work (allowing for variations in subtitles or editions)
              - The authors match (allowing for variations in name format)
              - The result is the actual book, not a study guide, companion, or analysis of the book

              Examples of what IS a match:
              - Different editions of the same book
              - Slight variations in title formatting
              - Presence or absence of edition information in title (e.g. "Original 1925 Edition", "Annotated Edition")
              - Different ISBN/EAN numbers for the same book
              - Hardcover vs Paperback editions
              - Kindle vs physical vs audiobook editions
              - Publisher variations
            CRITERIA
          end

          def non_match_criteria
            <<~CRITERIA.strip
              - Study guides or companion books
              - Books about the original book
              - Different books by the same author
              - Different volumes or parts of a series
              - SparkNotes or CliffsNotes editions
              - Abridged versions (unless the original is also abridged)
            CRITERIA
          end

          # Books care about the author, the publisher and the publication date --
          # the three fields that tell one printing from another.
          def format_search_result(result)
            item_info = result["itemInfo"] || {}
            contributors = item_info.dig("byLineInfo", "contributors") || []
            author = contributors.find { |c| c["role"] == "Author" }&.dig("name")

            <<~RESULT
              - ASIN: #{result["asin"]}
                Title: #{item_info.dig("title", "displayValue")}
                Author: #{author}
                Format: #{item_info.dig("classifications", "binding", "displayValue")}
                Publisher: #{item_info.dig("byLineInfo", "manufacturer", "displayValue")}
                Publication Date: #{item_info.dig("contentInfo", "publicationDate", "displayValue")}
            RESULT
          end

          class MatchResult < OpenAI::BaseModel
            required :asin, String, doc: "Amazon ASIN of the matching product"
            required :title, String, doc: "Product title from Amazon"
            required :author, String, doc: "Author name from Amazon"
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
