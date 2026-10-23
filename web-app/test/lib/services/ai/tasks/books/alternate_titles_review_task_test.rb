require "test_helper"

module Services
  module Ai
    module Tasks
      module Books
        class AlternateTitlesReviewTaskTest < ActiveSupport::TestCase
          Entry = AlternateTitlesReviewTask::Entry

          setup do
            @book = books_books(:war_and_peace)
            @entries = [Entry.new(key: "1", title: "Capítulo 22"), Entry.new(key: "2", title: "Voyna i mir")]
            @task = AlternateTitlesReviewTask.new(parent: @book, entries: @entries, accepted: ["Guerre et paix"])
          end

          def result(overrides = {})
            {key: "1", verdict: "not_same_work", category: "volume_or_part", confidence: 0.9, reason: "A chapter."}.merge(overrides)
          end

          test "results are keyed by number" do
            outcome = @task.send(:process_and_persist, {parsed: {results: [result, result(key: "2", verdict: "same_work", category: "translation")]}})

            assert outcome.success?
            assert_equal %w[1 2], outcome.data[:results].keys
            assert_equal "volume_or_part", outcome.data[:results]["1"][:category]
            assert_equal 0.9, outcome.data[:results]["1"][:confidence]
          end

          test "malformed results leave rows unjudged" do
            response = {parsed: {results: [
              result,
              result(reason: "second answer"),
              result(key: "9"),
              result(key: "2", verdict: "same_work", category: "other_work"),
              result(key: "2", confidence: 1.4)
            ]}}

            outcome = @task.send(:process_and_persist, response)

            assert_equal ["1"], outcome.data[:results].keys
            assert_equal "A chapter.", outcome.data[:results]["1"][:reason]
          end

          test "a repeated key whose answers disagree is dropped" do
            response = {parsed: {results: [
              result,
              result(verdict: "same_work", category: "translation"),
              result(key: "2", verdict: "same_work", category: "translation"),
              result(key: "2", verdict: "same_work", category: "translation", confidence: 0.5)
            ]}}

            outcome = @task.send(:process_and_persist, response)

            assert_equal ["2"], outcome.data[:results].keys
          end

          test "a repeated key that disagrees on category is dropped" do
            response = {parsed: {results: [result, result(category: "junk")]}}

            assert_empty @task.send(:process_and_persist, response).data[:results]
          end

          test "user prompt holds the book and numbered titles" do
            @book.update_columns(subtitle: "A Novel", first_published_year: 1869)
            prompt = AlternateTitlesReviewTask.new(parent: @book, entries: @entries, accepted: ["Guerre et paix"]).send(:user_prompt)

            assert_includes prompt, @book.title
            assert_includes prompt, "A Novel"
            assert_includes prompt, @book.authors.first.name
            assert_includes prompt, "1869"
            assert_includes prompt, "[1] \"Capítulo 22\""
            assert_includes prompt, "Guerre et paix"
          end

          test "system message does not prime removal and allows non-literal translations" do
            system = @task.send(:system_message)

            assert_not_includes system, "Many entries are wrong"
            assert_includes system, "not a literal translation"
            assert_includes system, "use a low confidence"
          end

          test "runs on the fast role" do
            assert_equal :fast, @task.send(:task_role)
            assert_equal AlternateTitlesReviewTask::ResponseSchema, @task.send(:response_schema)
          end
        end
      end
    end
  end
end
