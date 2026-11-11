require "test_helper"

module Services
  module Ai
    module Tasks
      module Books
        class CategoryChoiceTaskTest < ActiveSupport::TestCase
          setup do
            @book = books_books(:war_and_peace)
            @questions = [
              {proposed: "Georgia", category_type: "location", hint: "United States",
               candidates: [{id: 11, label: "Georgia › Caucasus"}, {id: 12, label: "Georgia › United States"}]},
              {proposed: "Chess", category_type: "subject", candidates: [{id: 21, label: "Chess"}]}
            ]
            @task = CategoryChoiceTask.new(parent: @book, book_line: "War and Peace by Leo Tolstoy", questions: @questions)
          end

          test "runs on the fast role" do
            assert_equal [:fast, :openai], [@task.send(:task_role), @task.send(:task_provider)]
          end

          test "the prompt lists each question's candidates with ids" do
            prompt = @task.send(:user_prompt)
            assert_includes prompt, "Book: War and Peace by Leo Tolstoy"
            assert_includes prompt, "1. Proposed location: \"Georgia\" (hint: United States)"
            assert_includes prompt, "11: Georgia › Caucasus"
            assert_includes prompt, "12: Georgia › United States"
            assert_includes prompt, "2. Proposed subject: \"Chess\"\n"
            assert_includes prompt, "21: Chess"
          end

          test "turns the parsed choices into numbered hashes" do
            parsed = {choices: [{question: 2, category_id: nil}, {question: 1, category_id: 12}]}
            result = @task.send(:process_and_persist, {parsed: parsed})
            assert result.success?
            assert_equal [{question: 1, category_id: 12}, {question: 2, category_id: nil}], result.data[:choices]
          end

          test "a non-numeric id becomes nil" do
            result = @task.send(:process_and_persist, {parsed: {choices: [{question: 1, category_id: "abc"}, {question: 2, category_id: 21}]}})
            assert_equal [{question: 1, category_id: nil}, {question: 2, category_id: 21}], result.data[:choices]
          end

          test "a reply with no choices fails" do
            assert_not @task.send(:process_and_persist, {parsed: {}}).success?
            assert_not @task.send(:process_and_persist, {parsed: nil}).success?
            assert_not @task.send(:process_and_persist, {parsed: {choices: nil}}).success?
          end

          test "a reply that omits a question fails" do
            result = @task.send(:process_and_persist, {parsed: {choices: [{question: 1, category_id: 12}]}})
            assert_not result.success?
            assert_match(/question\(s\) 2/, result.error)
          end

          test "the schema is choices" do
            assert_equal %w[choices], CategoryChoiceTask::ResponseSchema.to_json_schema[:properties].keys.map(&:to_s)
          end
        end
      end
    end
  end
end
