# frozen_string_literal: true

require "test_helper"

module Services
  module Ai
    module Tasks
      module Books
        class AmazonBookMatchTaskTest < ActiveSupport::TestCase
          def setup
            @book = books_books(:war_and_peace)
            @search_results = [
              {
                "asin" => "1400079985",
                "itemInfo" => {
                  "title" => {"displayValue" => "War and Peace (Vintage Classics)"},
                  "byLineInfo" => {
                    "contributors" => [{"role" => "Author", "name" => "Leo Tolstoy"}],
                    "manufacturer" => {"displayValue" => "Vintage"}
                  },
                  "classifications" => {"binding" => {"displayValue" => "Paperback"}},
                  "contentInfo" => {"publicationDate" => {"displayValue" => "2008-10-14T00:00:01Z"}}
                }
              },
              {
                "asin" => "0553213504",
                "itemInfo" => {
                  "title" => {"displayValue" => "CliffsNotes on Tolstoy's War and Peace"},
                  "classifications" => {"binding" => {"displayValue" => "Paperback"}}
                }
              }
            ]
            @task = AmazonBookMatchTask.new(parent: @book, search_results: @search_results)
          end

          test "domain_name returns book" do
            assert_equal "book", @task.send(:domain_name)
          end

          test "item_description includes the title and the author names" do
            description = @task.send(:item_description)

            assert_includes description, "War and Peace"
            assert_includes description, "Leo Tolstoy"
          end

          test "item_description includes the first published year when present" do
            description = @task.send(:item_description)

            assert_includes description, "1869"
          end

          test "item_description includes alternate titles when present" do
            description = @task.send(:item_description)

            assert_includes description, "Voyna i mir"
          end

          test "non_match_criteria rules out study guides" do
            criteria = @task.send(:non_match_criteria)

            assert_includes criteria, "CliffsNotes"
          end

          test "match_criteria allows different bindings of the same work" do
            criteria = @task.send(:match_criteria)

            assert_includes criteria, "Hardcover"
          end

          test "format_search_result exposes author, publisher and publication date" do
            formatted = @task.send(:format_search_result, @search_results.first)

            assert_includes formatted, "1400079985"
            assert_includes formatted, "Leo Tolstoy"
            assert_includes formatted, "Vintage"
            assert_includes formatted, "2008-10-14"
          end

          test "response schema requires asin title author and explanation" do
            properties = AmazonBookMatchTask::MatchResult.to_json_schema
              .dig(:properties)
              &.keys
              &.map(&:to_s)

            assert_equal %w[asin author explanation title], properties.sort
          end

          # The CliffsNotes fixture carries no byLineInfo at all. Anthologies and
          # many non-trade editions are the same. Rendering must produce a blank
          # Author line, never raise.
          test "format_search_result renders a result with no contributors without raising" do
            formatted = @task.send(:format_search_result, @search_results.second)

            assert_includes formatted, "0553213504"
            assert_includes formatted, "CliffsNotes"
            assert_match(/Author:\s*$/, formatted)
          end

          test "system_message combines the domain name and both criteria blocks" do
            message = @task.send(:system_message)

            assert_includes message, "book expert"
            assert_includes message, "same literary work"
            assert_includes message, "CliffsNotes"
          end

          test "user_prompt threads every search result through the formatter" do
            prompt = @task.send(:user_prompt)

            assert_includes prompt, "1400079985"
            assert_includes prompt, "0553213504"
            assert_includes prompt, "War and Peace"
            assert_includes prompt, "Leo Tolstoy"
          end

          # A labelled line with nothing after it is noise the model has to interpret.
          # These fields are optional and must be omitted entirely, not left blank.
          test "item_description omits subtitle and alternate titles when the book has neither" do
            plain = ::Books::Book.find(books_books(:crime_and_punishment).id)
            task = AmazonBookMatchTask.new(parent: plain, search_results: @search_results)

            description = task.send(:item_description)

            refute_includes description, "Subtitle:"
            refute_includes description, "Alternate Titles:"
            assert_includes description, "Crime and Punishment"
          end
        end
      end
    end
  end
end
