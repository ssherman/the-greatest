require "test_helper"

module Services
  module Ai
    module Tasks
      module Books
        class GenreSplitCheckTaskTest < ActiveSupport::TestCase
          Book = GenreSplitCheckTask::Book

          setup do
            @task = GenreSplitCheckTask.new(genre: "Science Fiction Fantasy", targets: ["Science Fiction", "Fantasy"], books: [
              Book.new(key: "1", title: "The Lord of the Rings", authors: ["J. R. R. Tolkien"], year: 1954, description: nil, genres: ["Fantasy"]),
              Book.new(key: "2", title: "Obscure Pamphlet", authors: [], year: nil, description: nil, genres: [])
            ])
          end

          test "runs on the standard role and shows each book's facts" do
            assert_equal :standard, @task.send(:task_role)
            prompt = @task.send(:user_prompt)
            assert_includes prompt, "[1] The Lord of the Rings by J. R. R. Tolkien (1954)"
            assert_includes prompt, "Other genres: Fantasy"
          end

          test "accepts a subset, an empty answer and unknown" do
            outcome = @task.send(:process_and_persist, {parsed: {results: [
              {key: "1", targets: ["Fantasy"], unknown: false, reason: "High fantasy."},
              {key: "2", targets: [], unknown: true, reason: "Not known."}
            ]}})
            assert outcome.success?
            assert_equal({"1" => ["Fantasy"], "2" => :unknown}, outcome.data[:results])
          end

          test "fails the batch on a target that is not offered" do
            refute @task.send(:process_and_persist, {parsed: {results: [
              {key: "1", targets: ["Horror"], unknown: false, reason: ""}, {key: "2", targets: [], unknown: true, reason: ""}
            ]}}).success?
          end
        end
      end
    end
  end
end
