require "test_helper"

module Services
  module Ai
    module Tasks
      module Lists
        module Music
          module Albums
            class ListItemsValidatorTaskTest < ActiveSupport::TestCase
              def setup
                @list = lists(:music_albums_list)
                @list.list_items.destroy_all

                @item1 = @list.list_items.create!(
                  position: 1,
                  verified: false,
                  metadata: {
                    "title" => "The Dark Side of the Moon",
                    "artists" => ["Pink Floyd"],
                    "album_id" => 123,
                    "album_name" => "The Dark Side of the Moon",
                    "opensearch_artist_names" => ["Pink Floyd"],
                    "opensearch_match" => true,
                    "opensearch_score" => 18.5
                  }
                )

                @item2 = @list.list_items.create!(
                  position: 2,
                  verified: false,
                  metadata: {
                    "title" => "Abbey Road",
                    "artists" => ["The Beatles"],
                    "mb_release_group_id" => "a1b2c3d4-5e6f-7a8b-9c0d-1e2f3a4b5c6d",
                    "mb_release_group_name" => "Abbey Road (Live)",
                    "mb_artist_names" => ["The Beatles"],
                    "musicbrainz_match" => true
                  }
                )

                @item3 = @list.list_items.create!(
                  position: 3,
                  verified: false,
                  metadata: {
                    "title" => "Nevermind",
                    "artists" => ["Nirvana"]
                  }
                )

                @task = ListItemsValidatorTask.new(parent: @list)
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
                assert_includes system_message, "Compilations"
              end

              test "user_prompt includes OpenSearch matched items with artist and source tag" do
                user_prompt = @task.send(:user_prompt)

                assert_includes user_prompt, "Pink Floyd - The Dark Side of the Moon"
                assert_match(/Matched: "Pink Floyd - The Dark Side of the Moon" \[OpenSearch\]/, user_prompt)
              end

              test "user_prompt includes MusicBrainz matched items with source tag" do
                user_prompt = @task.send(:user_prompt)

                assert_includes user_prompt, "The Beatles - Abbey Road"
                assert_includes user_prompt, "Abbey Road (Live)"
                assert_includes user_prompt, "[MusicBrainz]"
              end

              test "user_prompt excludes items with no enrichment" do
                user_prompt = @task.send(:user_prompt)

                refute_includes user_prompt, "Nevermind"
              end

              test "user_prompt numbers items starting from 1" do
                user_prompt = @task.send(:user_prompt)

                assert_includes user_prompt, "1. Original:"
                assert_includes user_prompt, "2. Original:"
              end

              test "user_prompt formats Original to Matched with source tag" do
                user_prompt = @task.send(:user_prompt)

                assert_match(/Original:.*→.*Matched:.*\[OpenSearch\]/, user_prompt)
                assert_match(/Original:.*→.*Matched:.*\[MusicBrainz\]/, user_prompt)
              end

              test "process_and_persist marks invalid matches in metadata" do
                provider_response = {
                  parsed: {
                    invalid: [2],
                    reasoning: "Abbey Road (Live) is a live album"
                  }
                }

                chat = mock
                @task.stubs(:chat).returns(chat)

                result = @task.send(:process_and_persist, provider_response)

                assert result.success?

                @item1.reload
                @item2.reload

                refute @item1.metadata.key?("ai_match_invalid")
                assert_equal true, @item2.metadata["ai_match_invalid"]
              end

              test "process_and_persist sets verified true for valid matches" do
                provider_response = {
                  parsed: {
                    invalid: [2],
                    reasoning: "Item 2 is invalid"
                  }
                }

                chat = mock
                @task.stubs(:chat).returns(chat)

                @task.send(:process_and_persist, provider_response)

                @item1.reload
                @item2.reload

                assert @item1.verified?
                refute @item2.verified?
              end

              test "process_and_persist clears listable_id for invalid OpenSearch matches" do
                album = music_albums(:dark_side_of_the_moon)
                @item1.update!(listable: album)

                provider_response = {
                  parsed: {
                    invalid: [1],
                    reasoning: "Item 1 is invalid OpenSearch match"
                  }
                }

                chat = mock
                @task.stubs(:chat).returns(chat)

                @task.send(:process_and_persist, provider_response)

                @item1.reload
                assert_nil @item1.listable_id
                assert_equal true, @item1.metadata["ai_match_invalid"]
              end

              test "process_and_persist removes ai_match_invalid for valid matches" do
                @item1.update!(metadata: @item1.metadata.merge("ai_match_invalid" => true))

                provider_response = {
                  parsed: {
                    invalid: [],
                    reasoning: "All matches are valid"
                  }
                }

                chat = mock
                @task.stubs(:chat).returns(chat)

                @task.send(:process_and_persist, provider_response)

                @item1.reload
                refute @item1.metadata.key?("ai_match_invalid")
              end

              test "process_and_persist handles empty invalid array (all valid)" do
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
                assert_equal 2, result.data[:verified_count]
              end

              test "process_and_persist returns correct counts including verified_count" do
                provider_response = {
                  parsed: {
                    invalid: [2],
                    reasoning: "Item 2 is a live album"
                  }
                }

                chat = mock
                @task.stubs(:chat).returns(chat)

                result = @task.send(:process_and_persist, provider_response)

                assert result.success?
                assert_equal 1, result.data[:valid_count]
                assert_equal 1, result.data[:invalid_count]
                assert_equal 2, result.data[:total_count]
                assert_equal 1, result.data[:verified_count]
                assert_equal "Item 2 is a live album", result.data[:reasoning]
                assert_equal chat, result.ai_chat
              end

              test "enriched_items returns only items with enrichment" do
                enriched = @task.send(:enriched_items)

                assert_equal 2, enriched.count
                assert_includes enriched, @item1
                assert_includes enriched, @item2
                refute_includes enriched, @item3
              end

              test "enriched_items includes items with listable_id" do
                album = music_albums(:dark_side_of_the_moon)
                @item3.update!(listable: album, metadata: {"title" => "Nevermind", "artists" => ["Nirvana"]})

                enriched = @task.send(:enriched_items)

                assert_equal 3, enriched.count
                assert_includes enriched, @item3
              end

              test "ResponseSchema has correct structure" do
                schema = ListItemsValidatorTask::ResponseSchema

                assert_includes schema.name, "ResponseSchema"
                assert schema < OpenAI::BaseModel
              end

              test "user_prompt returns empty string when no enriched items" do
                @item1.destroy
                @item2.destroy

                task = ListItemsValidatorTask.new(parent: @list)
                user_prompt = task.send(:user_prompt)

                assert_equal "", user_prompt
              end
            end
          end
        end
      end
    end
  end
end
