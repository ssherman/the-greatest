require "test_helper"

module Services
  module Ai
    module Tasks
      module CategoryCleanup
        class LocationTaskTest < ActiveSupport::TestCase
          Entry = BaseCleanupTask::Entry

          setup do
            @entries = [
              Entry.new(key: "1", name: "Chicago", links: 812, samples: ["Native Son by Richard Wright"], alternative_names: []),
              Entry.new(key: "2", name: "Hope", links: 2746, samples: ["The Grapes of Wrath by John Steinbeck"], alternative_names: ["Hope, Arkansas"])
            ]
            @task = LocationTask.new(entries: @entries, known_names: ["Illinois", "United States", "North America"], tier: :head)
          end

          def result(overrides = {})
            {key: "1", verdict: "real_place", canonical_name: "Chicago", merge_into: nil,
             parent_chain: ["Illinois", "United States", "North America"], place_kind: "city",
             retype_to: nil, ambiguous: false, reason: "City in Illinois."}.merge(overrides)
          end

          test "runs on the standard role with a strict schema and needs no parent" do
            assert_equal :standard, @task.send(:task_role)
            assert_equal LocationTask::ResponseSchema, @task.send(:response_schema)
          end

          test "the prompt numbers each location with its count, samples and other names" do
            prompt = @task.send(:user_prompt)
            assert_includes prompt, "[1] \"Chicago\" (812 books)"
            assert_includes prompt, "Native Son by Richard Wright"
            assert_includes prompt, "Other names: Hope, Arkansas"
          end

          test "the system prompt carries the naming and hierarchy rules and the known names" do
            system = @task.send(:system_message)
            assert_includes system, "A country's parent is always its continent"
            assert_includes system, "\"Paris\", not \"Paris, France\""
            assert_includes system, "Illinois\nUnited States\nNorth America"
            assert_includes system, "a DIFFERENT known location (never its own name)"
            assert_includes system, "unless merge_into is set"
            assert_includes system, "Empty only for a root"
          end

          test "keeps valid results keyed by number and drops unknown keys, repeats and verdicts" do
            response = {parsed: {results: [
              result,
              result(key: "1", canonical_name: "Second answer"),
              result(key: "9"),
              result(key: "2", verdict: "maybe")
            ]}}

            outcome = @task.send(:process_and_persist, response)

            assert outcome.success?
            assert_equal ["1"], outcome.data[:results].keys
            assert_equal "Chicago", outcome.data[:results]["1"][:canonical_name]
            assert_equal ["Illinois", "United States", "North America"], outcome.data[:results]["1"][:parent_chain]
          end

          test "an unknown place kind or retype target becomes nil" do
            outcome = @task.send(:process_and_persist, {parsed: {results: [result(place_kind: "planet", retype_to: "genre")]}})
            parsed = outcome.data[:results]["1"]
            assert_nil parsed[:place_kind]
            assert_nil parsed[:retype_to]
          end

          test "reads results that are OpenAI::BaseModel instances, as the provider returns them" do
            model = LocationTask::LocationResult.new(result)
            outcome = @task.send(:process_and_persist, {parsed: {results: [model]}})
            assert_equal "Chicago", outcome.data[:results]["1"][:canonical_name]
            assert_equal "city", outcome.data[:results]["1"][:place_kind]
          end

          test "the schema lists every field" do
            fields = LocationTask::LocationResult.to_json_schema[:properties].keys.map(&:to_s)
            assert_equal %w[key verdict canonical_name merge_into parent_chain place_kind retype_to ambiguous reason], fields
          end
        end
      end
    end
  end
end
