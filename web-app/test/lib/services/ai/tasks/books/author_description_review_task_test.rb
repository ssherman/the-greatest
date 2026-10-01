require "test_helper"

module Services
  module Ai
    module Tasks
      module Books
        class AuthorDescriptionReviewTaskTest < ActiveSupport::TestCase
          def setup
            @author = books_authors(:tolstoy)
          end

          def task(**options) = AuthorDescriptionReviewTask.new(parent: @author, description: "A Russian novelist.", **options)

          test "runs on the fast role with json mode and its own schema" do
            subject = task

            assert_equal :fast, subject.send(:task_role)
            assert_equal({type: "json_object"}, subject.send(:response_format))
            keys = AuthorDescriptionReviewTask::ResponseSchema.to_json_schema[:properties].keys.map(&:to_s)
            assert_equal %w[rewritten style_violations], keys.sort
          end

          test "the rules judge copied phrasing and an opening name, not spoilers" do
            message = task.send(:system_message)

            assert_includes message, "copied_phrasing"
            assert_includes message, "names_author_at_start"
            refute_includes message, "spoiler"
          end

          test "the prompt carries the author, the draft and the source text" do
            prompt = task(source_text: "Lead text here.").send(:user_prompt)

            assert_includes prompt, "Author: Leo Tolstoy"
            assert_includes prompt, "Description to review:\nA Russian novelist."
            assert_includes prompt, "Source text the description was written from, for comparison only:\nLead text here."
          end

          test "without source text there is no source section" do
            refute_includes task.send(:user_prompt), "Source text"
          end

          test "problems the code found reach the reviewer in words" do
            prompt = task(flagged: %w[copied too_long]).send(:user_prompt)

            assert_includes prompt, "Automated checks found that the description repeats eight or more consecutive " \
              "words of the source text; is over 140 words."
          end

          test "an em dash flag names the spaced en dash too" do
            prompt = task(flagged: %w[em_dash]).send(:user_prompt)

            assert_includes prompt, "spaced en dash"
          end

          test "the rules tell the reviewer to catch a spaced en dash" do
            assert_includes task.send(:system_message), "spaced en dash"
          end

          test "a parsed reply becomes a symbol-keyed hash, and an empty one an empty hash" do
            parsed = task.send(:process_and_persist, {parsed: {"style_violations" => ["semicolon"], "rewritten" => "Fixed."}})
            empty = task.send(:process_and_persist, {parsed: nil})

            assert_equal({style_violations: ["semicolon"], rewritten: "Fixed."}, parsed.data)
            assert_equal({}, empty.data)
          end
        end
      end
    end
  end
end
