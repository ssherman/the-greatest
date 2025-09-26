require "test_helper"

module Services
  module Ai
    module Tasks
      class BaseTaskTest < ActiveSupport::TestCase
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
          @task = ArtistDescriptionTask.new(parent: @artist)
        end

        test "should initialize with parent" do
          assert_equal @artist, @task.send(:parent)
        end

        test "should have default temperature" do
          assert_equal 1.0, @task.send(:temperature)
        end

        test "should_create_provider_strategy_correctly" do
          # Test that the correct provider strategy is created
          Services::Ai::Providers::OpenaiStrategy.expects(:new).returns(@mock_strategy)
          ArtistDescriptionTask.new(parent: @artist)
        end

        test "should_call_provider_with_correct_parameters" do
          # Mock the chat creation
          mock_chat = mock
          mock_chat.stubs(:save!).returns(true)
          mock_chat.stubs(:messages).returns([])
          mock_chat.stubs(:model).returns("gpt-4o")
          mock_chat.stubs(:provider_key).returns("openai")
          mock_chat.stubs(:temperature).returns(0.2)
          mock_chat.stubs(:raw_responses).returns([])
          AiChat.stubs(:create!).returns(mock_chat)

          # Expect the provider to be called with correct parameters
          @mock_strategy.expects(:send_message!).with(
            ai_chat: mock_chat,
            content: kind_of(String),
            response_format: {type: "json_object"},
            schema: ArtistDescriptionTask::ResponseSchema
          ).returns(mock_provider_response)

          @task.call
        end

        test "should_handle_chat_save_errors" do
          # Mock the chat creation to fail
          AiChat.stubs(:create!).raises(ActiveRecord::RecordInvalid.new(AiChat.new))

          result = @task.call

          refute result.success?
          assert_includes result.error, "Validation failed"
        end

        test "should_build_messages_correctly" do
          # Mock the provider response
          mock_response = mock_provider_response
          @mock_strategy.stubs(:send_message!).returns(mock_response)

          # Mock the chat creation
          mock_chat = mock
          mock_chat.stubs(:save!).returns(true)
          mock_chat.stubs(:messages).returns([])
          mock_chat.stubs(:model).returns("gpt-4o")
          mock_chat.stubs(:provider_key).returns("openai")
          mock_chat.stubs(:temperature).returns(0.2)
          mock_chat.stubs(:raw_responses).returns([])
          AiChat.stubs(:create!).returns(mock_chat)

          # Capture the messages passed to AiChat.create!
          captured_messages = nil
          AiChat.stubs(:create!).with do |args|
            captured_messages = args[:messages]
            true
          end.returns(mock_chat)

          @task.call

          # The system message is added in create_chat!, user message in add_user_message
          # But since AiChat.create! is only called once, only the system message is present at creation
          assert_equal 1, captured_messages.length
          roles = captured_messages.map { |msg| msg[:role] }
          assert_includes roles, "system"
          system_message = captured_messages.find { |msg| msg[:role] == "system" }
          assert system_message
          assert system_message[:content].present?, "System message should have content"
        end

        test "should_return_successful_result_with_correct_data" do
          # Mock the provider response
          mock_response = mock_provider_response
          @mock_strategy.stubs(:send_message!).returns(mock_response)

          # Mock the chat creation
          mock_chat = mock
          mock_chat.stubs(:save!).returns(true)
          mock_chat.stubs(:messages).returns([])
          mock_chat.stubs(:model).returns("gpt-4o")
          mock_chat.stubs(:provider_key).returns("openai")
          mock_chat.stubs(:temperature).returns(0.2)
          mock_chat.stubs(:raw_responses).returns([])
          AiChat.stubs(:create!).returns(mock_chat)

          result = @task.call

          assert result.success?
          assert_equal mock_response[:parsed], result.data
          assert_equal mock_chat, result.ai_chat
          assert_nil result.error
        end

        private

        def mock_provider_response(data = nil)
          default_data = {
            description: "Innovative English singer-songwriter and actor",
            born_on: "1947-01-08",
            year_died: 2016,
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
