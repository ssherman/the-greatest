require "test_helper"

module Services
  module Ai
    module Tasks
      module Books
        class GenreDraftTaskTest < ActiveSupport::TestCase
          Entry = GenreDraftTask::Entry

          setup do
            @task = GenreDraftTask.new(entries: [
              Entry.new(name: "Science fiction", books: 7181, samples: ["Dune by Frank Herbert"], references: 100),
              Entry.new(name: "Ebooks", books: 52, samples: [], references: 0)
            ])
          end

          def genres(*names) = names.map { |n| {name: n, definition: "x"} }

          test "runs on the premium role" do
            assert_equal :premium, @task.send(:task_role)
          end

          test "the prompt carries the rules and every genre with its counts" do
            system = @task.send(:system_message)
            assert_includes system, "what the book is about"
            assert_includes system, "40 to 60"
            assert_includes system, "Romantasy"
            assert_includes system, "Fiction, Nonfiction, Religion & Spirituality and Poetry"
            prompt = @task.send(:user_prompt)
            assert_includes prompt, "Science fiction (7181 books, used by 100 saved searches or recommendation settings)"
            assert_includes prompt, "Dune by Frank Herbert"
          end

          test "accepts a list that keeps the protected genres" do
            outcome = @task.send(:process_and_persist, {parsed: {genres: genres("Fiction", "Nonfiction", "Religion & Spirituality", "Poetry", "Science Fiction"), notes: ["Ebooks is a format."]}})
            assert outcome.success?
            assert_equal 5, outcome.data[:genres].size
            assert_equal ["Ebooks is a format."], outcome.data[:notes]
          end

          test "reads OpenAI::BaseModel genres" do
            models = ["Fiction", "Nonfiction", "Religion & Spirituality", "Poetry"].map { |n| GenreDraftTask::DraftGenre.new(name: n, definition: "x") }
            outcome = @task.send(:process_and_persist, {parsed: {genres: models, notes: []}})
            assert outcome.success?, outcome.error
            assert_equal "Fiction", outcome.data[:genres].first[:name]
          end

          test "fails when a protected genre is missing or a name repeats" do
            refute @task.send(:process_and_persist, {parsed: {genres: genres("Fiction", "Science Fiction"), notes: []}}).success?
            refute @task.send(:process_and_persist, {parsed: {genres: genres("Fiction", "Nonfiction", "Religion & Spirituality", "Poetry", "Poetry"), notes: []}}).success?
          end
        end
      end
    end
  end
end
