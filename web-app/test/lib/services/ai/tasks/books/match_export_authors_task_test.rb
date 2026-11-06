require "test_helper"

module Services
  module Ai
    module Tasks
      module Books
        class MatchExportAuthorsTaskTest < ActiveSupport::TestCase
          setup do
            @book = ::Books::Book.create!(title: "Breaking Free")
            @author = ::Books::Author.create!(name: "Daniel Dennett")
            @book.book_authors.create!(author: @author, position: 1)
            ["Consciousness Explained", "Darwin's Dangerous Idea"].each { |t| ::Books::Book.create!(title: t).book_authors.create!(author: @author, position: 1) }
            @task = MatchExportAuthorsTask.new(title: "Breaking Free", year: 1991, export_names: ["Daniel C. Dennett", "Chip Heath"],
              authors: [@author], book_id: @book.id)
          end

          test "runs on the fast role with json mode and needs no parent" do
            assert_equal [:fast, :openai, {type: "json_object"}], [@task.send(:task_role), @task.send(:task_provider), @task.send(:response_format)]
          end

          test "the prompt lists the export names and each author's other books, not this one" do
            prompt = @task.send(:user_prompt)

            assert_includes prompt, "- Daniel C. Dennett"
            assert_includes prompt, "1. Daniel Dennett"
            assert_includes prompt, "Consciousness Explained"
            assert_includes prompt, "Darwin's Dangerous Idea"
            assert_includes prompt, "other books: "
            refute_includes prompt.split("other books: ").last, "Breaking Free"
            assert_includes @task.send(:system_message), "Matching names alone prove nothing"
          end

          test "parses matches, nulls an out-of-range number and drops names that were not asked about" do
            response = {parsed: {reasoning: "Same books.", matches: [
              {export_name: "Daniel C. Dennett", author_number: 1, confidence: "high"},
              {export_name: "Chip Heath", author_number: 7, confidence: "high"},
              {export_name: "Someone Else", author_number: 1, confidence: "high"}
            ]}}

            result = @task.send(:process_and_persist, response)

            assert result.success?
            assert_equal [{export_name: "Daniel C. Dennett", author_number: 1, confidence: "high"},
              {export_name: "Chip Heath", author_number: nil, confidence: "high"}], result.data[:matches]
          end

          test "an unknown confidence is a failure" do
            result = @task.send(:process_and_persist, {parsed: {reasoning: "", matches: [{export_name: "Chip Heath", author_number: nil, confidence: "sure"}]}})

            refute result.success?
            assert_match(/confidence/, result.error)
          end

          test "the response schema is a class-level json schema" do
            assert_equal %w[matches reasoning], MatchExportAuthorsTask::ResponseSchema.to_json_schema[:properties].keys.map(&:to_s)
            assert_equal %w[export_name author_number confidence], MatchExportAuthorsTask::Match.to_json_schema[:properties].keys.map(&:to_s)
          end
        end
      end
    end
  end
end
