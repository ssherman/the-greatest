require "test_helper"

module Services
  module Ai
    module Tasks
      module Matching
        class SelectCandidateTaskTest < ActiveSupport::TestCase
          def setup
            @lines = [
              "War and Peace | by Leo Tolstoy | (1869) | ranked #3 | in catalog",
              "Voyna i mir | by Lev Tolstoy | (1867) | in catalog",
              "War and Peace | by Leo Tolstoy | open_library OL1W | open_library verdict accept"
            ]
            @task = SelectCandidateTask.new(
              parent: nil, entity_noun: "book", query_line: "War & Peace | by Tolstoy",
              candidate_lines: @lines, guidance: "Prefer the original novel over an abridgement."
            )
          end

          test "accepts a nil parent" do
            assert_nothing_raised { SelectCandidateTask.new(parent: nil, entity_noun: "book", query_line: "x", candidate_lines: []) }
          end

          test "uses gpt-5-mini on openai with json mode" do
            assert_equal :openai, @task.send(:task_provider)
            assert_equal "gpt-5-mini", @task.send(:task_model)
            assert_equal({type: "json_object"}, @task.send(:response_format))
          end

          test "system message names the entity, the ranked rule, the identifier caveat and the domain guidance" do
            message = @task.send(:system_message)

            assert_includes message, "incoming book"
            assert_includes message, "ranked"
            assert_includes message, "identifiers in this catalog are sometimes wrong"
            assert_includes message, "same_entity_groups"
            assert_includes message, "Prefer the original novel over an abridgement."
          end

          test "user prompt numbers the candidates from 1 and asks for 0 when none match" do
            prompt = @task.send(:user_prompt)

            assert_includes prompt, "Incoming book: War & Peace | by Tolstoy"
            assert_includes prompt, "1. War and Peace | by Leo Tolstoy | (1869) | ranked #3 | in catalog"
            assert_includes prompt, "3. War and Peace | by Leo Tolstoy | open_library OL1W"
            assert_includes prompt, "0 for none"
          end

          test "response schema has the four fields and a nested group model" do
            keys = SelectCandidateTask::ResponseSchema.to_json_schema.dig(:properties).keys.map(&:to_s)

            assert_equal %w[selected_index confidence reasoning same_entity_groups], keys
            assert_equal ["members"], SelectCandidateTask::Group.to_json_schema.dig(:properties).keys.map(&:to_s)
          end

          test "process_and_persist returns the selection with cleaned groups" do
            response = {parsed: {selected_index: 1, confidence: "high", reasoning: "Same work.", same_entity_groups: [{members: [2, 1, 2]}, {members: [3]}, {members: [1, 9]}]}}

            result = @task.send(:process_and_persist, response)

            assert result.success?
            assert_equal 1, result.data[:selected_index]
            assert_equal "high", result.data[:confidence]
            assert_equal "Same work.", result.data[:reasoning]
            assert_equal [[1, 2]], result.data[:same_entity_groups]
          end

          test "process_and_persist accepts 0 for none and an empty group list" do
            result = @task.send(:process_and_persist, {parsed: {selected_index: 0, confidence: "medium", reasoning: "None.", same_entity_groups: []}})

            assert result.success?
            assert_equal 0, result.data[:selected_index]
            assert_equal [], result.data[:same_entity_groups]
          end

          test "process_and_persist reads groups given as string-keyed hashes or objects" do
            group = Struct.new(:members).new([3, 2])
            result = @task.send(:process_and_persist, {parsed: {selected_index: 0, confidence: "low", reasoning: "", same_entity_groups: [{"members" => [1, 2]}, group]}})

            assert_equal [[1, 2], [2, 3]], result.data[:same_entity_groups]
          end

          test "process_and_persist fails on an out-of-range index" do
            result = @task.send(:process_and_persist, {parsed: {selected_index: 4, confidence: "high", reasoning: "", same_entity_groups: []}})

            assert result.failure?
            assert_includes result.error, "selected_index"
          end

          test "process_and_persist fails on an unknown confidence" do
            result = @task.send(:process_and_persist, {parsed: {selected_index: 1, confidence: "certain", reasoning: "", same_entity_groups: []}})

            assert result.failure?
            assert_includes result.error, "confidence"
          end
        end
      end
    end
  end
end
