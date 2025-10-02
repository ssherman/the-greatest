# frozen_string_literal: true

require "test_helper"

module Services
  module Ai
    module Tasks
      class AmazonAlbumMatchTaskTest < ActiveSupport::TestCase
        def setup
          @album = music_albums(:dark_side_of_the_moon)
          @search_results = mock_search_results
          @task = AmazonAlbumMatchTask.new(parent: @album, search_results: @search_results)
        end

        test "task_provider returns openai" do
          assert_equal :openai, @task.send(:task_provider)
        end

        test "task_model returns gpt-5-mini" do
          assert_equal "gpt-5-mini", @task.send(:task_model)
        end

        test "temperature returns 1.0" do
          assert_equal 1.0, @task.send(:temperature)
        end

        test "response_format returns json_object" do
          assert_equal({type: "json_object"}, @task.send(:response_format))
        end

        test "system_message contains proper instructions" do
          system_message = @task.send(:system_message)

          assert_includes system_message, "music expert"
          assert_includes system_message, "Amazon product search result"
          assert_includes system_message, "titles represent the same musical work"
          assert_includes system_message, "artists match"
          assert_includes system_message, "actual album, not merchandise"
        end

        test "user_prompt includes album information" do
          user_prompt = @task.send(:user_prompt)

          assert_includes user_prompt, @album.title
          assert_includes user_prompt, @album.artists.first.name
          assert_includes user_prompt, "Amazon search results:"
        end

        test "user_prompt includes search results" do
          user_prompt = @task.send(:user_prompt)

          assert_includes user_prompt, "B001234567"
          assert_includes user_prompt, "The Dark Side of the Moon"
          assert_includes user_prompt, "Pink Floyd"
        end

        test "user_prompt includes release year when present" do
          @album.update!(release_year: 1973)

          user_prompt = @task.send(:user_prompt)

          assert_includes user_prompt, "Release Year: 1973"
        end

        test "user_prompt excludes release year when not present" do
          @album.update!(release_year: nil)

          user_prompt = @task.send(:user_prompt)

          refute_includes user_prompt, "Release Year:"
        end

        test "process_and_persist returns success result with matching results" do
          provider_response = {
            parsed: {
              matching_results: [
                {
                  asin: "B001234567",
                  title: "The Dark Side of the Moon",
                  artist: "Pink Floyd",
                  explanation: "Exact match for the album"
                }
              ]
            }
          }

          # Mock the chat object
          chat = mock
          @task.stubs(:chat).returns(chat)

          result = @task.send(:process_and_persist, provider_response)

          assert result.success?
          assert_equal 1, result.data[:matching_results].count
          assert_equal "B001234567", result.data[:matching_results].first[:asin]
          assert_equal chat, result.ai_chat
        end

        test "process_and_persist handles empty matching results" do
          provider_response = {
            parsed: {
              matching_results: []
            }
          }

          chat = mock
          @task.stubs(:chat).returns(chat)

          result = @task.send(:process_and_persist, provider_response)

          assert result.success?
          assert_equal [], result.data[:matching_results]
        end

        test "ResponseSchema has correct structure" do
          schema = AmazonAlbumMatchTask::ResponseSchema

          # OpenAI::BaseModel uses the full class name
          assert_includes schema.name, "ResponseSchema"
          assert schema < OpenAI::BaseModel
        end

        test "task accepts custom provider and model" do
          task = AmazonAlbumMatchTask.new(
            parent: @album,
            search_results: @search_results,
            provider: :anthropic,
            model: "claude-3-5-sonnet-20241022"
          )

          # The custom provider/model would be handled by the parent class
          # We just verify the task can be instantiated with these params
          assert_equal @search_results, task.search_results
        end

        private

        def mock_search_results
          [
            {
              "ASIN" => "B001234567",
              "ItemInfo" => {
                "Title" => {"DisplayValue" => "The Dark Side of the Moon"},
                "ByLineInfo" => {
                  "Contributors" => [
                    {"Role" => "Artist", "Name" => "Pink Floyd"}
                  ],
                  "Manufacturer" => {"DisplayValue" => "Capitol Records"}
                },
                "Classifications" => {
                  "Binding" => {"DisplayValue" => "Audio CD"}
                },
                "ProductInfo" => {
                  "ReleaseDate" => {"DisplayValue" => "1994-08-02"}
                }
              }
            },
            {
              "ASIN" => "B007654321",
              "ItemInfo" => {
                "Title" => {"DisplayValue" => "Dark Side of the Moon Poster"},
                "ByLineInfo" => {
                  "Contributors" => [
                    {"Role" => "Artist", "Name" => "Unknown"}
                  ]
                },
                "Classifications" => {
                  "Binding" => {"DisplayValue" => "Poster"}
                }
              }
            }
          ]
        end
      end
    end
  end
end
