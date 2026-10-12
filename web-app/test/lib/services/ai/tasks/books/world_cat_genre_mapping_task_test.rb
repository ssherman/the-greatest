require "test_helper"

module Services
  module Ai
    module Tasks
      module Books
        class WorldCatGenreMappingTaskTest < ActiveSupport::TestCase
          setup do
            @terms = [["Romans", 85115, 40000], ["Large type books", 5495, 4000], ["Bildungsromans", 3281, 2000]]
            @genres = ["Fiction", "Coming of age", "Nonfiction"]
            @task = WorldCatGenreMappingTask.new(terms: @terms, genres: @genres)
          end

          test "runs on the standard role with json mode and needs no parent" do
            assert_equal :standard, @task.send(:task_role)
            assert_equal :openai, @task.send(:task_provider)
            assert_equal({type: "json_object"}, @task.send(:response_format))
            assert_equal WorldCatGenreMappingTask::ResponseSchema, @task.send(:response_schema)
          end

          test "the prompt lists every term with its counts and every genre" do
            prompt = @task.send(:user_prompt)
            assert_match(/Romans \(85115 uses on 40000 books\)/, prompt)
            assert_match(/Coming of age/, prompt)
            assert_match(/Large type books/, prompt)
          end

          test "the schema has verdicts with term, verdict, genre, subject, language and reason" do
            schema = WorldCatGenreMappingTask::ResponseSchema.to_json_schema
            assert_equal ["verdicts"], schema[:properties].keys.map(&:to_s)
            item = WorldCatGenreMappingTask::Verdict.to_json_schema
            assert_equal %w[term verdict genre subject language reason], item[:properties].keys.map(&:to_s)
          end

          test "keeps well-formed verdicts and rejects a genre not in the list" do
            response = {parsed: {verdicts: [
              {term: "Romans", verdict: "genre", genre: "Fiction", subject: nil, language: "fr", reason: nil},
              {term: "Large type books", verdict: "drop", genre: nil, subject: nil, language: "en", reason: "format"},
              {term: "Bildungsromans", verdict: "genre", genre: "Coming of age", subject: nil, language: "en", reason: nil}
            ]}}
            result = @task.send(:process_and_persist, response)
            assert result.success?
            assert_equal %w[Romans Large\ type\ books Bildungsromans], result.data[:verdicts].map { |v| v[:term] }
            assert_equal "Coming of age", result.data[:verdicts].last[:genre]

            bad = {parsed: {verdicts: [{term: "Romans", verdict: "genre", genre: "Novels", subject: nil, language: "fr", reason: nil}]}}
            assert_not @task.send(:process_and_persist, bad).success?
          end

          test "a verdict for a term that was not asked about is dropped, and a missing term fails" do
            extra = {parsed: {verdicts: [
              {term: "Romans", verdict: "genre", genre: "Fiction", subject: nil, language: "fr", reason: nil},
              {term: "Large type books", verdict: "drop", genre: nil, subject: nil, language: "en", reason: "format"},
              {term: "Bildungsromans", verdict: "subject", genre: nil, subject: "Coming of age", language: "en", reason: nil},
              {term: "Not asked", verdict: "drop", genre: nil, subject: nil, language: "en", reason: "format"}
            ]}}
            result = @task.send(:process_and_persist, extra)
            assert result.success?
            assert_equal 3, result.data[:verdicts].size

            missing = {parsed: {verdicts: [{term: "Romans", verdict: "genre", genre: "Fiction", subject: nil, language: "fr", reason: nil}]}}
            result = @task.send(:process_and_persist, missing)
            assert_not result.success?
            assert_match(/Large type books/, result.error)
          end
        end
      end
    end
  end
end
