require "test_helper"

module Services
  module Ai
    module Tasks
      module Books
        class GenreMapTaskTest < ActiveSupport::TestCase
          Entry = GenreMapTask::Entry

          setup do
            @genres = [{"name" => "Science Fiction", "definition" => "x"}, {"name" => "Fantasy", "definition" => "y"}]
            @audiences = [{"name" => "Children's", "definition" => "z"}]
            @task = GenreMapTask.new(genres: @genres, audiences: @audiences, entries: [
              Entry.new(key: "1", name: "Science Fiction Fantasy", books: 252, samples: [], references: 0, worldcat_terms: ["Fantasy och science fiction"]),
              Entry.new(key: "2", name: "Ebooks", books: 52, samples: [], references: 3, worldcat_terms: [])
            ])
          end

          def result(overrides = {})
            {key: "2", action: "delete", to: nil, into: [], into_subjects: [], as: nil, also: [], worldcat: nil, worldcat_terms: [], reason: "A format."}.merge(overrides)
          end

          test "the prompt lists the genres, audiences, each genre's WorldCat terms and the split rule" do
            assert_includes @task.send(:system_message), "split"
            prompt = @task.send(:user_prompt)
            assert_includes prompt, "Science Fiction: x"
            assert_includes prompt, "Children's: z"
            assert_includes prompt, "[1] \"Science Fiction Fantasy\" (252 books"
            assert_includes prompt, "WorldCat terms: Fantasy och science fiction"
          end

          test "accepts a split with worldcat_terms and a delete" do
            outcome = @task.send(:process_and_persist, {parsed: {results: [
              result(key: "1", action: "split", into: ["Science Fiction", "Fantasy"],
                worldcat_terms: [{term: "Fantasy och science fiction", targets: ["Science Fiction", "Fantasy"]}]),
              result
            ]}})
            assert outcome.success?, outcome.error
            assert_equal ["Science Fiction", "Fantasy"], outcome.data[:results]["1"][:into]
            assert_equal({"Fantasy och science fiction" => ["Science Fiction", "Fantasy"]}, outcome.data[:results]["1"][:worldcat_terms])
          end

          test "fails the batch on an off-list name, an unknown action, or a missing key" do
            refute @task.send(:process_and_persist, {parsed: {results: [result(key: "1", action: "merge", into: ["Space Opera"]), result]}}).success?
            refute @task.send(:process_and_persist, {parsed: {results: [result(key: "1", action: "explode"), result]}}).success?
            refute @task.send(:process_and_persist, {parsed: {results: [result]}}).success?
          end

          test "reads OpenAI::BaseModel results" do
            model = GenreMapTask::MapResult.new(result(key: "1", action: "merge", into: ["Fantasy"]))
            outcome = @task.send(:process_and_persist, {parsed: {results: [model, result]}})
            assert_equal ["Fantasy"], outcome.data[:results]["1"][:into]
          end
        end
      end
    end
  end
end
