require "test_helper"

module Services
  module Ai
    module Tasks
      module Books
        class LocationTrimTaskTest < ActiveSupport::TestCase
          setup do
            @book = books_books(:war_and_peace)
            @locations = [
              LocationTrimTask::Location.new(id: 11, trail: "Moscow, Russia"),
              LocationTrimTask::Location.new(id: 12, trail: "Paris, France")
            ]
            @task = LocationTrimTask.new(book: @book, locations: @locations)
          end

          test "runs on the standard role, parented on the book" do
            assert_equal :standard, @task.send(:task_role)
          end

          test "the prompt lists each location with its id and trail" do
            prompt = @task.send(:user_prompt)
            assert_includes prompt, @book.title
            assert_includes prompt, "[11] Moscow, Russia"
            assert_includes prompt, "[12] Paris, France"
          end

          test "drops ids that were not offered" do
            outcome = @task.send(:process_and_persist, {parsed: {keep_ids: [11, 99], reason: "Set in Moscow."}})

            assert outcome.success?
            assert_equal [11], outcome.data[:keep_ids]
          end

          test "the schema has keep_ids and reason" do
            assert_equal %w[keep_ids reason], LocationTrimTask::ResponseSchema.to_json_schema[:properties].keys.map(&:to_s)
          end
        end
      end
    end
  end
end
