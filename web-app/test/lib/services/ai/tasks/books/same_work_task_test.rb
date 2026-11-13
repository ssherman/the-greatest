require "test_helper"

module Services
  module Ai
    module Tasks
      module Books
        class SameWorkTaskTest < ActiveSupport::TestCase
          setup do
            @facts = ::Services::Books::GoodreadsReimport::EditionFacts::Facts.new(
              full_title: "The Hobbit, or There and Back Again", title: "The Hobbit", subtitle: "or There and Back Again",
              primary_author: "J.R.R. Tolkien", author_names: ["J.R.R. Tolkien", "Jane Translator"], year: 1937,
              isbn13: "9780000000001", isbn10: nil, goodreads_book_id: 5907, series_name: nil, series_number: nil
            )
            @first = ::Books::Book.create!(title: "The Hobbit", subtitle: "There and Back Again", first_published_year: 1937)
            @first.book_authors.create!(author: ::Books::Author.create!(name: "J.R.R. Tolkien"), position: 1)
            %w[One Two Three Four].each { |t| @first.editions.create!(title: "Hobbit Edition #{t}") }
            @second = ::Books::Book.create!(title: "Der Hobbit", first_published_year: 1957)
            @second.book_authors.create!(author: ::Books::Author.create!(name: "Tolkien"), position: 1)
            @task = SameWorkTask.new(facts: @facts, books: [@first, @second])
          end

          test "runs on the fast role with json mode and needs no parent" do
            assert_equal [:fast, :openai, {type: "json_object"}], [@task.send(:task_role), @task.send(:task_provider), @task.send(:response_format)]
          end

          test "the prompt shows the row's facts and every numbered candidate" do
            prompt = @task.send(:user_prompt)

            assert_includes prompt, "The Hobbit, or There and Back Again"
            assert_includes prompt, "J.R.R. Tolkien"
            assert_includes prompt, "Jane Translator"
            assert_includes prompt, "1937"
            assert_includes prompt, "1. The Hobbit: There and Back Again"
            assert_includes prompt, "2. Der Hobbit"
            assert_includes prompt, "1957"
            assert_includes prompt, "Tolkien"
            assert_includes prompt, "Hobbit Edition One"
            assert_includes prompt, "Hobbit Edition Three"
            refute_includes prompt, "Hobbit Edition Four"
          end

          test "the system message states the same-work rules" do
            message = @task.send(:system_message)

            assert_match(/translation/i, message)
            assert_match(/different volume/i, message)
            assert_match(/adaptation/i, message)
            assert_match(/box set/i, message)
            assert_match(/combo/i, message)
            assert_match(/English/, message)
            assert_match(/translators/, message)
            assert_match(/different year alone/i, message)
          end

          test "maps the candidate number back to the book id" do
            result = @task.send(:process_and_persist, {parsed: {candidate_number: 2, confidence: "high", reason: "x"}})

            assert result.success?
            assert_equal({book_id: @second.id, confidence: "high", reason: "x"}, result.data)
          end

          test "a null candidate number means none is the same work" do
            result = @task.send(:process_and_persist, {parsed: {candidate_number: nil, confidence: "medium", reason: "none"}})

            assert result.success?
            assert_nil result.data[:book_id]
          end

          test "an out-of-range number is a failure" do
            [0, 3, -1].each do |number|
              result = @task.send(:process_and_persist, {parsed: {candidate_number: number, confidence: "high", reason: "x"}})

              refute result.success?
            end
          end

          test "an unknown confidence is a failure" do
            result = @task.send(:process_and_persist, {parsed: {candidate_number: 1, confidence: "sure", reason: "x"}})

            refute result.success?
            assert_match(/confidence/, result.error)
          end

          test "the response schema is a class-level json schema" do
            assert_equal %w[candidate_number confidence reason], SameWorkTask::ResponseSchema.to_json_schema[:properties].keys.map(&:to_s)
          end
        end
      end
    end
  end
end
