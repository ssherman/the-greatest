require "test_helper"

module Services
  module Ai
    module Tasks
      module Books
        class GroupSameAuthorsTaskTest < ActiveSupport::TestCase
          setup do
            @lines = [
              "J.D. Robb | wrote: Naked in Death; Glory in Death",
              "J. D. Robb | wrote: Immortal in Death",
              "JD Robb | 1931–2019 | wrote: A Cookbook of Soups"
            ]
            @task = GroupSameAuthorsTask.new(author_lines: @lines)
          end

          test "runs on the fast role with json mode and needs no parent" do
            assert_equal :fast, @task.send(:task_role)
            assert_equal :openai, @task.send(:task_provider)
            assert_equal({type: "json_object"}, @task.send(:response_format))
          end

          test "the prompt numbers the authors and says a shared name proves nothing" do
            assert_includes @task.send(:user_prompt), "1. J.D. Robb | wrote: Naked in Death; Glory in Death"
            assert_includes @task.send(:user_prompt), "3. JD Robb"
            assert_includes @task.send(:system_message), "Matching names alone prove nothing"
            assert_includes @task.send(:system_message), "pen name"
          end

          test "keeps valid groups, drops out-of-range and repeated members, and groups of one" do
            response = {parsed: {reasoning: "Same books.", groups: [
              {members: [2, 1, 9], confidence: "high"}, {members: [1, 3], confidence: "low"}, {members: [3], confidence: "high"}
            ]}}

            result = @task.send(:process_and_persist, response)

            assert result.success?
            assert_equal [{members: [1, 2], confidence: "high"}], result.data[:groups]
            assert_equal "Same books.", result.data[:reasoning]
          end

          test "an unknown confidence is a failure" do
            result = @task.send(:process_and_persist, {parsed: {reasoning: "", groups: [{members: [1, 2], confidence: "sure"}]}})

            refute result.success?
            assert_match(/confidence/, result.error)
          end

          test "the response schema has groups of members with a confidence, and reasoning" do
            assert_equal %w[groups reasoning], GroupSameAuthorsTask::ResponseSchema.to_json_schema[:properties].keys.map(&:to_s)
            assert_equal %w[members confidence], GroupSameAuthorsTask::Group.to_json_schema[:properties].keys.map(&:to_s)
          end
        end
      end
    end
  end
end
