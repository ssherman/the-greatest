require "test_helper"

module Services
  module Ai
    module Tasks
      module Music
        module Songs
          class RecordingMatcherTaskTest < ActiveSupport::TestCase
            def setup
              @song = music_songs(:wish_you_were_here)
              @candidates = [
                {
                  "id" => "aaa-111-111-111",
                  "title" => "Wish You Were Here",
                  "artist-credit" => [{"name" => "Pink Floyd"}],
                  "first-release-date" => "1975-09-12",
                  "disambiguation" => ""
                },
                {
                  "id" => "bbb-222-222-222",
                  "title" => "Wish You Were Here (live)",
                  "artist-credit" => [{"name" => "Pink Floyd"}],
                  "first-release-date" => "1988-11-28",
                  "disambiguation" => "live at Wembley"
                },
                {
                  "id" => "ccc-333-333-333",
                  "title" => "Wish You Were Here (2011 remaster)",
                  "artist-credit" => [{"name" => "Pink Floyd"}],
                  "first-release-date" => "2011-09-26",
                  "disambiguation" => "remastered"
                }
              ]
              @task = RecordingMatcherTask.new(parent: @song, candidates: @candidates)
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

            test "response_format returns json_object" do
              assert_equal({type: "json_object"}, @task.send(:response_format))
            end

            test "system_message contains matching instructions" do
              system_message = @task.send(:system_message)

              assert_includes system_message, "music expert"
              assert_includes system_message, "MusicBrainz recordings"
              assert_includes system_message, "SAME VERSION"
              assert_includes system_message, "INCLUDE as exact matches"
              assert_includes system_message, "EXCLUDE"
              assert_includes system_message, "Remasters"
              assert_includes system_message, "Live versions"
            end

            test "user_prompt includes song info" do
              user_prompt = @task.send(:user_prompt)

              assert_includes user_prompt, "Wish You Were Here"
              assert_includes user_prompt, "Pink Floyd"
              # NOTE: release_year intentionally NOT included - we want to find earliest year
              refute_includes user_prompt, "Release year:"
            end

            test "user_prompt includes candidate recordings" do
              user_prompt = @task.send(:user_prompt)

              assert_includes user_prompt, "aaa-111-111-111"
              assert_includes user_prompt, "bbb-222-222-222"
              assert_includes user_prompt, "ccc-333-333-333"
              assert_includes user_prompt, "(live)"
              assert_includes user_prompt, "(2011 remaster)"
              assert_includes user_prompt, "1975-09-12"
              assert_includes user_prompt, "live at Wembley"
            end

            test "user_prompt returns empty string when no candidates" do
              task = RecordingMatcherTask.new(parent: @song, candidates: [])
              user_prompt = task.send(:user_prompt)

              assert_equal "", user_prompt
            end

            test "handles nil candidates gracefully" do
              task = RecordingMatcherTask.new(parent: @song, candidates: nil)
              user_prompt = task.send(:user_prompt)

              assert_equal "", user_prompt
            end

            test "user_prompt numbers candidates starting from 1" do
              user_prompt = @task.send(:user_prompt)

              assert_includes user_prompt, "1. MBID:"
              assert_includes user_prompt, "2. MBID:"
              assert_includes user_prompt, "3. MBID:"
            end

            test "build_song_info includes title and artist but not release_year" do
              song_info = @task.send(:build_song_info)

              assert_includes song_info, "Wish You Were Here"
              assert_includes song_info, "Pink Floyd"
              # NOTE: release_year intentionally NOT included - we want to find earliest year
              refute_includes song_info, "1975"
              refute_includes song_info, "Release year"
            end

            test "build_candidates_list formats candidates correctly" do
              candidates_list = @task.send(:build_candidates_list)

              assert_includes candidates_list, "MBID: aaa-111-111-111"
              assert_includes candidates_list, "Title: \"Wish You Were Here\""
              assert_includes candidates_list, "Artist: Pink Floyd"
              assert_includes candidates_list, "First release: 1975-09-12"
              assert_includes candidates_list, "Disambiguation: live at Wembley"
            end

            test "process_and_persist returns exact_matches array" do
              provider_response = {
                parsed: {
                  exact_matches: ["aaa-111-111-111"],
                  reasoning: "Selected original studio recording",
                  excluded: [
                    {mbid: "bbb-222-222-222", reason: "live version"},
                    {mbid: "ccc-333-333-333", reason: "remaster"}
                  ]
                }
              }

              chat = mock
              @task.stubs(:chat).returns(chat)

              result = @task.send(:process_and_persist, provider_response)

              assert result.success?
              assert_equal ["aaa-111-111-111"], result.data[:exact_matches]
              assert_equal "Selected original studio recording", result.data[:reasoning]
              assert_equal 2, result.data[:excluded].count
            end

            test "process_and_persist handles empty exact_matches" do
              provider_response = {
                parsed: {
                  exact_matches: [],
                  reasoning: "No exact matches found",
                  excluded: []
                }
              }

              chat = mock
              @task.stubs(:chat).returns(chat)

              result = @task.send(:process_and_persist, provider_response)

              assert result.success?
              assert_equal [], result.data[:exact_matches]
            end

            test "process_and_persist handles nil excluded array" do
              provider_response = {
                parsed: {
                  exact_matches: ["aaa-111-111-111"],
                  reasoning: "Match found",
                  excluded: nil
                }
              }

              chat = mock
              @task.stubs(:chat).returns(chat)

              result = @task.send(:process_and_persist, provider_response)

              assert result.success?
              assert_equal [], result.data[:excluded]
            end

            test "ResponseSchema has correct structure" do
              schema = RecordingMatcherTask::ResponseSchema

              assert_includes schema.name, "ResponseSchema"
              assert schema < OpenAI::BaseModel
            end

            test "ExcludedRecording schema has correct structure" do
              schema = RecordingMatcherTask::ExcludedRecording

              assert_includes schema.name, "ExcludedRecording"
              assert schema < OpenAI::BaseModel
            end
          end
        end
      end
    end
  end
end
