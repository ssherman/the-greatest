require "test_helper"

module Services
  module Ai
    module Tasks
      module Books
        class BookFactsTaskTest < ActiveSupport::TestCase
          def setup
            @book = books_books(:war_and_peace)
          end

          test "runs on openai as an analysis chat with json mode" do
            task = BookFactsTask.new(parent: @book)

            assert_equal :openai, task.send(:provider).provider_key
            assert_equal :analysis, task.send(:chat_type)
            assert_equal({type: "json_object"}, task.send(:response_format))
            assert_equal BookFactsTask::ResponseSchema, task.send(:response_schema)
          end

          test "the schema is a class-level json schema with every fact" do
            keys = BookFactsTask::ResponseSchema.to_json_schema[:properties].keys.map(&:to_s)

            %w[recognized confidence first_published_year first_published_year_estimated original_language
              word_count page_range subtitle alternate_titles origin_countries book_type series_name
              series_number description].each do |key|
              assert_includes keys, key
            end
          end

          test "user prompt names the book, its authors and known year" do
            prompt = BookFactsTask.new(parent: @book).send(:user_prompt)

            assert_includes prompt, "War and Peace"
            assert_includes prompt, "Leo Tolstoy"
            assert_includes prompt, "1869"
          end

          test "user prompt uses passed author names when the book has none" do
            book = ::Books::Book.create!(title: "An Unattributed Work")
            prompt = BookFactsTask.new(parent: book, author_names: ["Someone Obscure"]).send(:user_prompt)

            assert_includes prompt, "Someone Obscure"
          end

          test "user prompt includes identifiers when present" do
            @book.identifiers.create!(identifier_type: :books_work_openlibrary_id, value: "OL262758W")
            prompt = BookFactsTask.new(parent: @book).send(:user_prompt)

            assert_includes prompt, "Open Library work key: OL262758W"
          end

          test "user prompt marks an existing description as context only" do
            prompt = BookFactsTask.new(parent: @book).send(:user_prompt)

            assert_includes prompt, "context only"
            assert_includes prompt, @book.primary_description.content
          end

          test "system message carries the description rules" do
            message = BookFactsTask.new(parent: @book).send(:system_message)

            assert_includes message, "Spoiler-free"
            assert_includes message, "60 to 110 words"
            assert_includes message, "em dashes"
            assert_includes message, "No citations, URLs"
          end

          test "research mode tells the model to verify with web search" do
            knowledge = BookFactsTask.new(parent: @book).send(:system_message)
            research = BookFactsTask.new(parent: @book, mode: :research).send(:system_message)

            refute_includes knowledge, "web search"
            assert_includes research, "web search"
          end
        end
      end
    end
  end
end
