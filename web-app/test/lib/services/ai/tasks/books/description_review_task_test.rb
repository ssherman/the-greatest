require "test_helper"

module Services
  module Ai
    module Tasks
      module Books
        class DescriptionReviewTaskTest < ActiveSupport::TestCase
          def setup
            @book = books_books(:war_and_peace)
            @task = DescriptionReviewTask.new(parent: @book, description: "A paragraph — with a dash.")
          end

          test "runs on the fast role with openai and json mode" do
            assert_equal :fast, @task.send(:task_role)
            assert_equal "gpt-6-luna", @task.instance_variable_get(:@model)
            assert_equal :openai, @task.send(:provider).provider_key
            assert_equal({type: "json_object"}, @task.send(:response_format))
            assert_equal DescriptionReviewTask::ResponseSchema, @task.send(:response_schema)
          end

          test "user prompt carries the description, the title and the authors so it can spot them" do
            prompt = @task.send(:user_prompt)

            assert_includes prompt, "A paragraph — with a dash."
            assert_includes prompt, "War and Peace"
            assert_includes prompt, "Leo Tolstoy"
          end

          test "user prompt uses passed author names when the book has none" do
            book = ::Books::Book.create!(title: "An Unattributed Work")
            task = DescriptionReviewTask.new(parent: book, description: "Some text.", author_names: ["Someone Obscure"])

            prompt = task.send(:user_prompt)

            assert_includes prompt, "Someone Obscure"
          end

          test "system message lists the violation codes" do
            message = @task.send(:system_message)

            DescriptionReviewTask::VIOLATIONS.each { |code| assert_includes message, code }
            assert_includes message, "spoiler"
          end

          test "process_and_persist returns the parsed review and writes nothing" do
            @task.stubs(:chat).returns(ai_chats(:general_chat))
            parsed = {spoilers: false, spoiler_notes: nil, style_violations: ["em_dash"], rewritten: "A paragraph, with a comma."}
            before = @book.descriptions.count

            result = @task.send(:process_and_persist, {parsed: parsed})

            assert result.success?
            assert_equal parsed, result.data
            assert_equal before, @book.descriptions.reload.count
          end
        end
      end
    end
  end
end
