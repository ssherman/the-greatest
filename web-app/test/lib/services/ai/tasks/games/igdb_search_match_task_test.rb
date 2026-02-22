# frozen_string_literal: true

require "test_helper"

module Services
  module Ai
    module Tasks
      module Games
        class IgdbSearchMatchTaskTest < ActiveSupport::TestCase
          def setup
            @list = lists(:games_list)
            @search_query = "The Legend of Zelda"
            @search_results = [
              {
                "id" => 1,
                "name" => "Zelda II: The Adventure of Link",
                "first_release_date" => 568598400,
                "involved_companies" => [
                  {"developer" => true, "company" => {"name" => "Nintendo"}}
                ]
              },
              {
                "id" => 2,
                "name" => "The Legend of Zelda",
                "first_release_date" => 509328000,
                "cover" => {"image_id" => "abc123"},
                "involved_companies" => [
                  {"developer" => true, "company" => {"name" => "Nintendo"}}
                ]
              },
              {
                "id" => 3,
                "name" => "The Legend of Zelda: Breath of the Wild",
                "first_release_date" => 1488499200,
                "involved_companies" => [
                  {"developer" => true, "company" => {"name" => "Nintendo EPD"}}
                ]
              }
            ]
            @task = IgdbSearchMatchTask.new(
              parent: @list,
              search_query: @search_query,
              search_results: @search_results,
              developers: ["Nintendo"]
            )
          end

          test "initializes with search_query, search_results, and developers" do
            assert_equal @search_query, @task.search_query
            assert_equal @search_results, @task.search_results
            assert_equal ["Nintendo"], @task.developers
          end

          test "defaults developers to empty array" do
            task = IgdbSearchMatchTask.new(
              parent: @list,
              search_query: @search_query,
              search_results: @search_results
            )
            assert_equal [], task.developers
          end

          test "handles nil developers" do
            task = IgdbSearchMatchTask.new(
              parent: @list,
              search_query: @search_query,
              search_results: @search_results,
              developers: nil
            )
            assert_equal [], task.developers
          end

          test "uses openai provider" do
            assert_equal :openai, @task.send(:task_provider)
          end

          test "uses gpt-5-mini model" do
            assert_equal "gpt-5-mini", @task.send(:task_model)
          end

          test "user_prompt includes search query" do
            prompt = @task.send(:user_prompt)
            assert_includes prompt, "The Legend of Zelda"
          end

          test "user_prompt includes developers when present" do
            prompt = @task.send(:user_prompt)
            assert_includes prompt, "Developers: Nintendo"
          end

          test "user_prompt omits top-level developers line when empty" do
            results_without_devs = [
              {"id" => 1, "name" => "Some Game"}
            ]
            task = IgdbSearchMatchTask.new(
              parent: @list,
              search_query: @search_query,
              search_results: results_without_devs,
              developers: []
            )
            prompt = task.send(:user_prompt)
            refute_includes prompt, "Developers:"
          end

          test "user_prompt includes numbered search results" do
            prompt = @task.send(:user_prompt)
            assert_includes prompt, '0. Name: "Zelda II: The Adventure of Link"'
            assert_includes prompt, '1. Name: "The Legend of Zelda"'
            assert_includes prompt, '2. Name: "The Legend of Zelda: Breath of the Wild"'
          end

          test "user_prompt includes release year from timestamp" do
            prompt = @task.send(:user_prompt)
            assert_includes prompt, "Release year: 1986"
          end

          test "user_prompt includes developer names from involved_companies" do
            prompt = @task.send(:user_prompt)
            assert_includes prompt, "Developers: Nintendo EPD"
          end

          test "user_prompt includes cover image indicator" do
            prompt = @task.send(:user_prompt)
            assert_includes prompt, "Has cover image: yes"
          end

          test "process_and_persist returns best match when index is valid" do
            provider_response = {
              parsed: {best_match_index: 1, confidence: "high", reasoning: "Exact title match"}
            }

            result = @task.send(:process_and_persist, provider_response)

            assert result.success?
            assert_equal @search_results[1], result.data[:best_match]
            assert_equal 1, result.data[:best_match_index]
            assert_equal "high", result.data[:confidence]
            assert_equal "Exact title match", result.data[:reasoning]
          end

          test "process_and_persist returns nil match when index is null" do
            provider_response = {
              parsed: {best_match_index: nil, confidence: "none", reasoning: "No results match"}
            }

            result = @task.send(:process_and_persist, provider_response)

            assert result.success?
            assert_nil result.data[:best_match]
            assert_nil result.data[:best_match_index]
            assert_equal "none", result.data[:confidence]
          end

          test "process_and_persist returns nil match when confidence is none" do
            provider_response = {
              parsed: {best_match_index: 0, confidence: "none", reasoning: "Low quality match"}
            }

            result = @task.send(:process_and_persist, provider_response)

            assert result.success?
            assert_nil result.data[:best_match]
            assert_nil result.data[:best_match_index]
          end

          test "process_and_persist returns failure when confidence is unexpected value" do
            provider_response = {
              parsed: {best_match_index: 0, confidence: "unknown", reasoning: "Unexpected"}
            }

            result = @task.send(:process_and_persist, provider_response)

            assert result.failure?
            assert_includes result.error, "Unexpected confidence value"
          end

          test "process_and_persist returns nil match when index is out of bounds" do
            provider_response = {
              parsed: {best_match_index: 99, confidence: "high", reasoning: "Bad index"}
            }

            result = @task.send(:process_and_persist, provider_response)

            assert result.success?
            assert_nil result.data[:best_match]
            assert_nil result.data[:best_match_index]
          end

          test "response_schema is defined with required fields" do
            schema = @task.send(:response_schema)
            assert_equal IgdbSearchMatchTask::ResponseSchema, schema
            assert schema < OpenAI::BaseModel
          end
        end
      end
    end
  end
end
