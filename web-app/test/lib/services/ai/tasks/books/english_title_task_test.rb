require "test_helper"

module Services
  module Ai
    module Tasks
      module Books
        class EnglishTitleTaskTest < ActiveSupport::TestCase
          setup do
            @facts = ::Services::Books::GoodreadsReimport::EditionFacts::Facts.new(
              full_title: "Der talentierte Mr. Ripley (Ripley, #1)", title: "Der talentierte Mr. Ripley", subtitle: nil,
              primary_author: "Patricia Highsmith", author_names: ["Patricia Highsmith", "Matthias Jendis"], year: 1955,
              isbn13: "9783257233001", isbn10: nil, goodreads_book_id: 1, series_name: "Ripley", series_number: "1"
            )
            @task = EnglishTitleTask.new(facts: @facts)
          end

          def respond(english_title, confidence = "high")
            @task.send(:process_and_persist, {parsed: {english_title: english_title, confidence: confidence, reason: "r"}})
          end

          test "runs on the fast role with json mode and needs no parent" do
            assert_equal [:fast, :openai, {type: "json_object"}], [@task.send(:task_role), @task.send(:task_provider), @task.send(:response_format)]
          end

          test "the prompt shows the edition's title, authors, year and series" do
            prompt = @task.send(:user_prompt)

            assert_includes prompt, "Der talentierte Mr. Ripley (Ripley, #1)"
            assert_includes prompt, "Patricia Highsmith; Matthias Jendis"
            assert_includes prompt, "1955"
            assert_includes prompt, "Ripley #1"
          end

          test "the system message asks for the English edition's title and null when there is none" do
            message = @task.send(:system_message)

            assert_match(/English/, message)
            assert_match(/translation/i, message)
            assert_match(/volume/i, message)
            assert_match(/null/, message)
          end

          test "returns the English title with its confidence" do
            result = respond("The Talented Mr. Ripley", "medium")

            assert result.success?
            assert_equal({title: "The Talented Mr. Ripley", confidence: "medium", reason: "r"}, result.data)
          end

          test "a null or blank title, or the edition's own title, means no English title" do
            [nil, " ", "der talentierte mr. ripley", "Der talentierte Mr. Ripley (Ripley, #1)"].each do |answer|
              result = respond(answer)

              assert result.success?, answer.inspect
              assert_nil result.data[:title], answer.inspect
            end
          end

          test "a low-confidence title is not used" do
            assert_nil respond("The Talented Mr. Ripley", "low").data[:title]
          end

          test "an unknown confidence is a failure" do
            result = respond("The Talented Mr. Ripley", "sure")

            refute result.success?
            assert_match(/confidence/, result.error)
          end

          test "the response schema is a class-level json schema" do
            assert_equal %w[english_title confidence reason], EnglishTitleTask::ResponseSchema.to_json_schema[:properties].keys.map(&:to_s)
          end
        end
      end
    end
  end
end
