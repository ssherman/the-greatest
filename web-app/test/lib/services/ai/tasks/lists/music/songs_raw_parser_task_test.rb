require "test_helper"

module Services
  module Ai
    module Tasks
      module Lists
        module Music
          class SongsRawParserTaskTest < ActiveSupport::TestCase
            def setup
              @list = lists(:music_songs_list)
              @list.update!(
                simplified_content: "<ul><li>1. Bohemian Rhapsody - Queen (A Night at the Opera)</li><li>Imagine - John Lennon</li></ul>"
              )

              # Mock the AI provider strategy
              @mock_strategy = mock
              @mock_strategy.stubs(:send_message!).returns(mock_provider_response)
              @mock_strategy.stubs(:provider_key).returns("openai")
              @mock_strategy.stubs(:default_model).returns("gpt-5")
              @mock_strategy.stubs(:capabilities).returns([:json_mode, :json_schema])

              # Stub the provider strategy creation
              Services::Ai::Providers::OpenaiStrategy.stubs(:new).returns(@mock_strategy)

              @task = SongsRawParserTask.new(parent: @list)
            end

            test "should successfully process songs data" do
              mock_response = mock_provider_response
              @mock_strategy.stubs(:send_message!).returns(mock_response)

              result = @task.call

              assert result.success?
              assert_equal mock_response[:parsed], result.data
              assert_not_nil result.ai_chat

              # Verify the list was updated with songs data
              @list.reload
              assert_not_nil @list.items_json
            end

            test "should handle provider errors gracefully" do
              @mock_strategy.stubs(:send_message!).raises(StandardError.new("API Error"))

              result = @task.call

              refute result.success?
              assert_includes result.error, "API Error"
            end

            private

            def mock_provider_response
              data = {
                songs: [
                  {
                    rank: 1,
                    title: "Bohemian Rhapsody",
                    artists: ["Queen"],
                    album: "A Night at the Opera",
                    release_year: 1975
                  },
                  {
                    rank: nil,
                    title: "Imagine",
                    artists: ["John Lennon"],
                    album: nil,
                    release_year: 1971
                  }
                ]
              }

              {
                content: data.to_json,
                parsed: data,
                id: "chatcmpl-123",
                model: "gpt-5",
                usage: {prompt_tokens: 45, completion_tokens: 30, total_tokens: 75}
              }
            end
          end
        end
      end
    end
  end
end
