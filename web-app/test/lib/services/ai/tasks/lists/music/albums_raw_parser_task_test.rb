require "test_helper"

module Services
  module Ai
    module Tasks
      module Lists
        module Music
          class AlbumsRawParserTaskTest < ActiveSupport::TestCase
            def setup
              @list = lists(:music_albums_list)
              @list.update!(
                simplified_html: "<ul><li>1. Abbey Road - The Beatles (1969)</li><li>The Dark Side of the Moon - Pink Floyd</li></ul>"
              )

              # Mock the AI provider strategy
              @mock_strategy = mock
              @mock_strategy.stubs(:send_message!).returns(mock_provider_response)
              @mock_strategy.stubs(:provider_key).returns("openai")
              @mock_strategy.stubs(:default_model).returns("gpt-5")
              @mock_strategy.stubs(:capabilities).returns([:json_mode, :json_schema])

              # Stub the provider strategy creation
              Services::Ai::Providers::OpenaiStrategy.stubs(:new).returns(@mock_strategy)

              @task = AlbumsRawParserTask.new(parent: @list)
            end

            test "should successfully process albums data" do
              mock_response = mock_provider_response
              @mock_strategy.stubs(:send_message!).returns(mock_response)

              result = @task.call

              assert result.success?
              assert_equal mock_response[:parsed], result.data
              assert_not_nil result.ai_chat

              # Verify the list was updated with albums data
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
                albums: [
                  {
                    rank: 1,
                    title: "Abbey Road",
                    artists: ["The Beatles"],
                    release_year: 1969
                  },
                  {
                    rank: nil,
                    title: "The Dark Side of the Moon",
                    artists: ["Pink Floyd"],
                    release_year: 1973
                  }
                ]
              }

              {
                content: data.to_json,
                parsed: data,
                id: "chatcmpl-123",
                model: "gpt-5",
                usage: {prompt_tokens: 50, completion_tokens: 25, total_tokens: 75}
              }
            end
          end
        end
      end
    end
  end
end
