require "test_helper"

module Services
  module Ai
    module Tasks
      module Lists
        module Music
          module Albums
            class ItemsJsonValidatorTaskTest < ActiveSupport::TestCase
              def setup
                @list = lists(:music_albums_list_with_items_json)
                @list.update!(items_json: {
                  "albums" => [
                    {
                      "rank" => 1,
                      "title" => "Dark Side of the Moon",
                      "artists" => ["Pink Floyd"],
                      "release_year" => 1973,
                      "mb_release_group_id" => "f5093c06-23e3-404f-afe0-f9df359d6e68",
                      "mb_release_group_name" => "The Dark Side of the Moon",
                      "mb_artist_ids" => ["83d91898-7763-47d7-b03b-b92132375c47"],
                      "mb_artist_names" => ["Pink Floyd"]
                    },
                    {
                      "rank" => 2,
                      "title" => "Abbey Road",
                      "artists" => ["The Beatles"],
                      "release_year" => 1969,
                      "mb_release_group_id" => "c9b0b3f7-6a0e-3d8b-8e5f-7f7c5a6e0f2a",
                      "mb_release_group_name" => "Abbey Road (Live)",
                      "mb_artist_ids" => ["b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"],
                      "mb_artist_names" => ["The Beatles"]
                    },
                    {
                      "rank" => 3,
                      "title" => "Revolver",
                      "artists" => ["The Beatles"],
                      "release_year" => 1966
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
                assert_includes system_message, "validates album matches"
                assert_includes system_message, "INVALID"
                assert_includes system_message, "Live albums"
                assert_includes system_message, "Tribute albums"
              end

              test "user_prompt includes enriched album information" do
                user_prompt = @task.send(:user_prompt)

                assert_includes user_prompt, "Pink Floyd - Dark Side of the Moon"
                assert_includes user_prompt, "Pink Floyd - The Dark Side of the Moon"
                assert_includes user_prompt, "The Beatles - Abbey Road"
                assert_includes user_prompt, "The Beatles - Abbey Road (Live)"
                refute_includes user_prompt, "Revolver"
              end

              test "user_prompt numbers albums starting from 1" do
                user_prompt = @task.send(:user_prompt)

                assert_includes user_prompt, "1. Original:"
                assert_includes user_prompt, "2. Original:"
              end

              test "process_and_persist marks invalid matches and updates list" do
                provider_response = {
                  parsed: {
                    invalid: [2],
                    reasoning: "Abbey Road (Live) is a live album, not the studio album"
                  }
                }

                chat = mock
                @task.stubs(:chat).returns(chat)

                result = @task.send(:process_and_persist, provider_response)

                assert result.success?
                assert_equal 1, result.data[:valid_count]
                assert_equal 1, result.data[:invalid_count]
                assert_equal 2, result.data[:total_count]
                assert_equal "Abbey Road (Live) is a live album, not the studio album", result.data[:reasoning]
                assert_equal chat, result.ai_chat

                @list.reload
                albums = @list.items_json["albums"]
                refute albums[0].key?("ai_match_invalid")
                assert_equal true, albums[1]["ai_match_invalid"]
                refute albums[2].key?("ai_match_invalid")
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
                albums = @list.items_json["albums"]
                refute albums[0].key?("ai_match_invalid")
                refute albums[1].key?("ai_match_invalid")
              end

              test "process_and_persist removes previous invalid flags when re-validated as valid" do
                @list.items_json["albums"][1]["ai_match_invalid"] = true
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
                albums = @list.items_json["albums"]
                refute albums[1].key?("ai_match_invalid")
              end

              test "ResponseSchema has correct structure" do
                schema = ItemsJsonValidatorTask::ResponseSchema

                assert_includes schema.name, "ResponseSchema"
                assert schema < OpenAI::BaseModel
              end

              test "task only validates enriched albums" do
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
