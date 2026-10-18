require "test_helper"

module Services
  module Ai
    module Tasks
      module CategoryCleanup
        class SubjectTaskTest < ActiveSupport::TestCase
          Entry = BaseCleanupTask::Entry

          def task(tier)
            SubjectTask.new(
              entries: [Entry.new(key: "1", name: "Spacecraft missions", links: 1, samples: [], alternative_names: [])],
              known_names: ["Space Exploration", "War"],
              tier: tier
            )
          end

          test "head prompt allows only true synonyms; tail prompt allows folding into a broader subject" do
            assert_includes task(:head).send(:system_message), "Never merge a narrower subject into a broader one"
            assert_includes task(:tail).send(:system_message), "too narrow to stand on its own"
            refute_includes task(:head).send(:system_message), "too narrow to stand on its own"
            assert_includes task(:head).send(:system_message), "Merge only true synonyms and variant spellings"
            refute_includes task(:tail).send(:system_message), "Merge only true synonyms and variant spellings"
            assert_includes task(:tail).send(:system_message), "a DIFFERENT known subject (never its own name)"
          end

          test "the prompt says an entry's own name in the known list is itself" do
            assert_includes task(:head).send(:system_message), "is the entry itself, not a different subject"
          end

          test "the prompt says audience is its own category type" do
            assert_includes task(:head).send(:system_message), "an audience (\"Young Adult\"), which is its own category type"
          end

          test "keeps a valid result and drops an unknown action" do
            outcome = task(:tail).send(:process_and_persist, {parsed: {results: [
              {key: "1", action: "merge", name: "Spacecraft Missions", merge_into: "Space Exploration", reason: "Covered."}
            ]}})
            assert_equal "Space Exploration", outcome.data[:results]["1"][:merge_into]

            bad = task(:tail).send(:process_and_persist, {parsed: {results: [{key: "1", action: "split", name: "", merge_into: nil, reason: ""}]}})
            assert_empty bad.data[:results]
          end

          test "the schema lists every field" do
            fields = SubjectTask::SubjectResult.to_json_schema[:properties].keys.map(&:to_s)
            assert_equal %w[key action name merge_into reason], fields
          end
        end
      end
    end
  end
end
