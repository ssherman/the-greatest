require "test_helper"

module Services
  module Ai
    module Tasks
      module Lists
        module Music
          module Songs
            class ItemsJsonValidatorTaskTest < ActiveSupport::TestCase
              def setup
                @list = lists(:music_songs_list_with_items_json)
                @list.update!(items_json: {
                  "songs" => [
                    {
                      "rank" => 1,
                      "title" => "Come Together",
                      "artists" => ["The Beatles"],
                      "release_year" => 1969,
                      "mb_recording_id" => "e3f3c2d4-55c2-4d28-bb47-71f42f2a5ccc",
                      "mb_recording_name" => "Come Together",
                      "mb_artist_ids" => ["b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"],
                      "mb_artist_names" => ["The Beatles"]
                    },
                    {
                      "rank" => 2,
                      "title" => "Imagine",
                      "artists" => ["John Lennon"],
                      "release_year" => 1971,
                      "mb_recording_id" => "a1b2c3d4-5e6f-7a8b-9c0d-1e2f3a4b5c6d",
                      "mb_recording_name" => "Imagine (Live)",
                      "mb_artist_ids" => ["4d5e6f7a-8b9c-0d1e-2f3a-4b5c6d7e8f9a"],
                      "mb_artist_names" => ["John Lennon"]
                    },
                    {
                      "rank" => 3,
                      "title" => "Hey Jude",
                      "artists" => ["The Beatles"],
                      "release_year" => 1968
                    }
                  ]
                })
                @task = ItemsJsonValidatorTask.new(parent: @list)
              end

              test "task_provider returns openai" do
                assert_equal :openai, @task.send(:task_provider)
              end

              test "task_model returns gpt-5-mini" do
                assert_equal "gpt-5-mini", @task.send(:task_model)
              end

              test "chat_type returns analysis" do
                assert_equal :analysis, @task.send(:chat_type)
              end

              test "temperature returns 1.0" do
                assert_equal 1.0, @task.send(:temperature)
              end

              test "response_format returns json_object" do
                assert_equal({type: "json_object"}, @task.send(:response_format))
              end

              test "system_message contains validation instructions" do
                system_message = @task.send(:system_message)

                assert_includes system_message, "music expert"
                assert_includes system_message, "validates song recording matches"
                assert_includes system_message, "INVALID"
                assert_includes system_message, "Live recordings"
                assert_includes system_message, "Cover versions"
              end

              test "user_prompt includes enriched song information" do
                user_prompt = @task.send(:user_prompt)

                assert_includes user_prompt, "The Beatles - Come Together"
                assert_includes user_prompt, "The Beatles - Come Together"
                assert_includes user_prompt, "John Lennon - Imagine"
                assert_includes user_prompt, "John Lennon - Imagine (Live)"
                refute_includes user_prompt, "Hey Jude"
              end

              test "user_prompt numbers songs starting from 1" do
                user_prompt = @task.send(:user_prompt)

                assert_includes user_prompt, "1. Original:"
                assert_includes user_prompt, "2. Original:"
              end

              test "process_and_persist marks invalid matches and updates list" do
                provider_response = {
                  parsed: {
                    invalid: [2],
                    reasoning: "Imagine (Live) is a live recording, not the studio version"
                  }
                }

                chat = mock
                @task.stubs(:chat).returns(chat)

                result = @task.send(:process_and_persist, provider_response)

                assert result.success?
                assert_equal 1, result.data[:valid_count]
                assert_equal 1, result.data[:invalid_count]
                assert_equal 2, result.data[:total_count]
                assert_equal "Imagine (Live) is a live recording, not the studio version", result.data[:reasoning]
                assert_equal chat, result.ai_chat

                @list.reload
                songs = @list.items_json["songs"]
                refute songs[0].key?("ai_match_invalid")
                assert_equal true, songs[1]["ai_match_invalid"]
                refute songs[2].key?("ai_match_invalid")
              end

              test "process_and_persist handles empty invalid array" do
                provider_response = {
                  parsed: {
                    invalid: [],
                    reasoning: "All matches are valid"
                  }
                }

                chat = mock
                @task.stubs(:chat).returns(chat)

                result = @task.send(:process_and_persist, provider_response)

                assert result.success?
                assert_equal 2, result.data[:valid_count]
                assert_equal 0, result.data[:invalid_count]
                assert_equal 2, result.data[:total_count]

                @list.reload
                songs = @list.items_json["songs"]
                refute songs[0].key?("ai_match_invalid")
                refute songs[1].key?("ai_match_invalid")
              end

              test "process_and_persist removes previous invalid flags when re-validated as valid" do
                @list.items_json["songs"][1]["ai_match_invalid"] = true
                @list.save!

                provider_response = {
                  parsed: {
                    invalid: [],
                    reasoning: "All matches are now valid"
                  }
                }

                chat = mock
                @task.stubs(:chat).returns(chat)

                @task.send(:process_and_persist, provider_response)

                @list.reload
                songs = @list.items_json["songs"]
                refute songs[1].key?("ai_match_invalid")
              end

              test "ResponseSchema has correct structure" do
                schema = ItemsJsonValidatorTask::ResponseSchema

                assert_includes schema.name, "ResponseSchema"
                assert schema < OpenAI::BaseModel
              end

              test "task only validates enriched songs" do
                user_prompt = @task.send(:user_prompt)

                lines = user_prompt.lines.select { |line| line.match?(/^\d+\./) }
                assert_equal 2, lines.count
              end
            end
          end
        end
      end
    end
  end
end
