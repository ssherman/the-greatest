require "test_helper"

module Services
  module Ai
    module Tasks
      class ArtistDetailsTaskTest < ActiveSupport::TestCase
        def setup
          @artist = music_artists(:david_bowie)

          # Mock the AI provider strategy
          @mock_strategy = mock
          @mock_strategy.stubs(:send_message!).returns(mock_provider_response)
          @mock_strategy.stubs(:provider_key).returns("openai")
          @mock_strategy.stubs(:default_model).returns("gpt-4o")
          @mock_strategy.stubs(:capabilities).returns([:json_mode, :json_schema])

          # Stub the provider strategy creation
          Services::Ai::Providers::OpenaiStrategy.stubs(:new).returns(@mock_strategy)

          # Create the task after mocking
          @task = ArtistDetailsTask.new(parent: @artist)
        end

        test "should have correct provider and model" do
          assert_equal :openai, @task.send(:task_provider)
          assert_equal "gpt-4o", @task.send(:task_model)
        end

        test "should generate correct system message" do
          system_message = @task.send(:system_message)

          assert_includes system_message, "music expert"
          assert_includes system_message, "extract detailed information"
          assert_includes system_message, "distinguish between individual people and bands"
          assert_includes system_message, "don't know or are unsure"
          assert_includes system_message, "better to indicate that than to guess"
        end

        test "should generate correct user prompt" do
          user_prompt = @task.send(:user_prompt)

          assert_includes user_prompt, "David Bowie"
          assert_includes user_prompt, "detailed information"
          assert_includes user_prompt, "description"
          assert_includes user_prompt, "country"
          assert_includes user_prompt, "kind"
          assert_includes user_prompt, "artist_known"
          assert_includes user_prompt, "don't know this artist"
          assert_includes user_prompt, "valid JSON matching the schema"
        end

        test "should have correct response format" do
          response_format = @task.send(:response_format)
          assert_equal({type: "json_object"}, response_format)
        end

        test "should have correct response schema" do
          schema = @task.send(:response_schema)
          assert_equal ArtistDetailsTask::ResponseSchema, schema
        end

        test "should process and persist valid response" do
          # Mock the provider response
          mock_response = mock_provider_response
          @mock_strategy.stubs(:send_message!).returns(mock_response)

          result = @task.call

          assert result.success?
          assert_equal mock_response[:parsed], result.data
          assert_not_nil result.ai_chat
          assert_kind_of AiChat, result.ai_chat
        end

        test "should update artist with extracted information when artist is known" do
          # Mock the provider response with specific data
          mock_response = mock_provider_response(
            artist_known: true,
            description: "Innovative English singer-songwriter",
            country: "GB",
            kind: "person"
          )
          @mock_strategy.stubs(:send_message!).returns(mock_response)

          result = @task.call

          # Verify the artist was updated
          @artist.reload
          assert_equal "Innovative English singer-songwriter", @artist.description
          assert_equal "GB", @artist.country
          assert_equal "person", @artist.kind

          assert result.success?
        end

        test "should handle missing optional fields gracefully when artist is known" do
          # Mock response with minimal data
          mock_response = mock_provider_response(
            artist_known: true,
            description: nil,
            country: nil,
            kind: "person"
          )
          @mock_strategy.stubs(:send_message!).returns(mock_response)

          result = @task.call

          # Verify the artist was updated with nil values for optional fields
          @artist.reload
          assert_nil @artist.description
          assert_nil @artist.country
          assert_equal "person", @artist.kind

          assert result.success?
        end

        test "should handle band type artists when artist is known" do
          @artist = music_artists(:pink_floyd)
          @task = ArtistDetailsTask.new(parent: @artist)

          # Mock response for a band
          mock_response = mock_provider_response(
            artist_known: true,
            description: "English progressive rock band",
            country: "GB",
            kind: "band"
          )
          @mock_strategy.stubs(:send_message!).returns(mock_response)

          result = @task.call

          # Verify the artist was updated
          @artist.reload
          assert_equal "English progressive rock band", @artist.description
          assert_equal "GB", @artist.country
          assert_equal "band", @artist.kind

          assert result.success?
        end

        test "should not update artist when artist is unknown" do
          # Store original values
          original_description = @artist.description
          original_country = @artist.country
          original_kind = @artist.kind

          # Mock response for unknown artist
          mock_response = mock_provider_response(
            artist_known: false,
            description: nil,
            country: nil,
            kind: nil
          )
          @mock_strategy.stubs(:send_message!).returns(mock_response)

          result = @task.call

          # Verify the artist was NOT updated (values remain the same)
          @artist.reload
          assert_equal original_description, @artist.description
          assert_equal original_country, @artist.country
          assert_equal original_kind, @artist.kind

          # But the result should still be successful
          assert result.success?
          assert_equal false, result.data[:artist_known]
        end

        test "should handle provider errors gracefully" do
          @mock_strategy.stubs(:send_message!).raises(StandardError.new("API Error"))

          result = @task.call

          refute result.success?
          assert_includes result.error, "API Error"
        end

        test "should handle artist update errors gracefully" do
          # Mock the provider response
          mock_response = mock_provider_response
          @mock_strategy.stubs(:send_message!).returns(mock_response)

          # Mock artist update to fail
          @artist.stubs(:update!).raises(ActiveRecord::RecordInvalid.new(@artist))

          result = @task.call

          refute result.success?
          assert_includes result.error, "Validation failed"
        end

        test "should create AI chat with correct parameters" do
          # Mock the provider response
          mock_response = mock_provider_response
          @mock_strategy.stubs(:send_message!).returns(mock_response)

          # Call the task and get the result
          result = @task.call

          # Assert the result is successful
          assert result.success?

          # Find the created AiChat
          ai_chat = result.ai_chat

          # Assert the chat was created with correct parameters
          assert_not_nil ai_chat
          assert_equal @artist, ai_chat.parent
          assert_equal "analysis", ai_chat.chat_type
          assert_equal "gpt-4o", ai_chat.model
          assert_equal "openai", ai_chat.provider
          assert_equal 0.2, ai_chat.temperature
          assert ai_chat.json_mode
          assert_not_nil ai_chat.response_schema
          assert_kind_of Array, ai_chat.messages
        end

        test "should include system and user messages in chat" do
          # Mock the provider response
          mock_response = mock_provider_response
          @mock_strategy.stubs(:send_message!).returns(mock_response)

          # Call the task and get the result
          result = @task.call

          # Assert the result is successful
          assert result.success?

          # Get the created AiChat
          ai_chat = result.ai_chat

          # The system message is added in create_chat!, user message in add_user_message
          # After processing, the chat should have both system and user messages
          assert ai_chat.messages.length >= 2
          roles = ai_chat.messages.map { |msg| msg["role"] }
          assert_includes roles, "system"
          assert_includes roles, "user"

          # Check system message content
          system_message = ai_chat.messages.find { |msg| msg["role"] == "system" }
          assert system_message
          assert_includes system_message["content"], "music expert"

          # Check user message content
          user_message = ai_chat.messages.find { |msg| msg["role"] == "user" }
          assert user_message
          assert_includes user_message["content"], "David Bowie"
        end

        private

        def mock_provider_response(data = nil)
          default_data = {
            artist_known: true,
            description: "Innovative English singer-songwriter and actor",
            country: "GB",
            kind: "person"
          }

          final_data = data || default_data

          {
            content: final_data.to_json,
            parsed: final_data,
            id: "chatcmpl-123",
            model: "gpt-4o",
            usage: {prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}
          }
        end
      end
    end
  end
end
