require "test_helper"

module Services
  module Ai
    module Tasks
      module Matching
        class SelectExternalRecordTaskTest < ActiveSupport::TestCase
          def setup
            @task = SelectExternalRecordTask.new(
              source_name: "Wikidata", entity_noun: "author",
              query_line: "Leo Tolstoy | 1828–1910 | wrote: War and Peace",
              candidate_lines: ["Leo Tolstoy | Russian writer | 1828–1910 | wikidata Q7243", "Lev Tolstoy | 1984 film | wikidata Q4256164"],
              guidance: "Our author wrote the books listed."
            )
          end

          test "is a select-one-or-none task on the fast role with the shared response schema" do
            assert_operator SelectExternalRecordTask, :<, SelectCandidateTask
            assert_equal :fast, @task.send(:task_role)
            assert_equal SelectCandidateTask::ResponseSchema, @task.send(:response_schema)
          end

          test "system message is about linking to the source, prefers no link to a wrong one, and carries the guidance" do
            message = @task.send(:system_message)

            assert_includes message, "Wikidata"
            assert_includes message, "No link is better than a wrong link"
            assert_includes message, "A shared name alone is not enough"
            assert_includes message, "year conflict"
            assert_includes message, "Our author wrote the books listed."
            assert_not_includes message, "already exists in a catalog"
          end

          test "user prompt numbers the records from 1 and asks for 0 when none match" do
            prompt = @task.send(:user_prompt)

            assert_includes prompt, "Our author: Leo Tolstoy | 1828–1910 | wrote: War and Peace"
            assert_includes prompt, "Wikidata records:"
            assert_includes prompt, "1. Leo Tolstoy | Russian writer"
            assert_includes prompt, "2. Lev Tolstoy | 1984 film"
            assert_includes prompt, "0 for none"
          end

          test "validates the selection against the number of records" do
            result = @task.send(:process_and_persist, {parsed: {selected_index: 3, confidence: "high", reasoning: "x", same_entity_groups: []}})

            assert_not result.success?
            assert_match(/outside 0..2/, result.error)
          end
        end
      end
    end
  end
end
