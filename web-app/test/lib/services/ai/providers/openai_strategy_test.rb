require "test_helper"

class Services::Ai::Providers::OpenaiStrategyTest < ActiveSupport::TestCase
  def setup
    @strategy = Services::Ai::Providers::OpenaiStrategy.new
    @ai_chat = ai_chats(:general_chat)
    @content = "Test message content"
    @response_format = {type: "json_object"}

    # Mock the client instead of OpenAI::Client.new
    @mock_client = mock
    @mock_chat = mock
    @mock_completions = mock
    @strategy.stubs(:client).returns(@mock_client)
    @mock_client.stubs(:chat).returns(@mock_chat)
    @mock_chat.stubs(:completions).returns(@mock_completions)
  end

  test "should have correct capabilities" do
    expected_capabilities = %i[json_mode json_schema function_calls]
    assert_equal expected_capabilities, @strategy.capabilities
  end

  test "should have correct default model" do
    assert_equal "gpt-5-mini", @strategy.default_model
  end

  test "should have correct provider key" do
    assert_equal :openai, @strategy.provider_key
  end

  test "should send message with basic parameters" do
    mock_response = create_mock_response('{"message": "Hello, world!"}')

    @mock_completions.expects(:create).with(
      {
        model: @ai_chat.model,
        messages: @ai_chat.messages + [{role: "user", content: @content}],
        temperature: @ai_chat.temperature.to_f
      }
    ).returns(mock_response)

    result = @strategy.send_message!(
      ai_chat: @ai_chat,
      content: @content,
      response_format: nil,
      schema: nil
    )

    assert_equal '{"message": "Hello, world!"}', result[:content]
    assert_equal({message: "Hello, world!"}, result[:parsed])
    assert_equal "chatcmpl-123", result[:id]
    assert_equal "gpt-4", result[:model]
    assert_equal({prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}, result[:usage])
  end

  test "should send message with response format when provided" do
    mock_response = create_mock_response('{"key": "value"}')

    @mock_completions.expects(:create).with(
      {
        model: @ai_chat.model,
        messages: @ai_chat.messages + [{role: "user", content: @content}],
        temperature: @ai_chat.temperature.to_f,
        response_format: @response_format
      }
    ).returns(mock_response)

    result = @strategy.send_message!(
      ai_chat: @ai_chat,
      content: @content,
      response_format: @response_format,
      schema: nil
    )

    assert_equal '{"key": "value"}', result[:content]
    assert_equal({key: "value"}, result[:parsed])
  end

  test "should send message with JSON schema when provided" do
    schema_class = Class.new(RubyLLM::Schema) do
      string :name, required: true
      string :description, required: false
    end

    mock_response = create_mock_response('{"name": "Test", "description": "A test"}')

    @mock_completions.expects(:create).with(
      {
        model: @ai_chat.model,
        messages: @ai_chat.messages + [{role: "user", content: @content}],
        temperature: @ai_chat.temperature.to_f,
        response_format: {
          type: "json_schema",
          json_schema: JSON.parse(schema_class.new.to_json)
        }
      }
    ).returns(mock_response)

    result = @strategy.send_message!(
      ai_chat: @ai_chat,
      content: @content,
      response_format: nil,
      schema: schema_class
    )

    assert_equal '{"name": "Test", "description": "A test"}', result[:content]
    assert_equal({name: "Test", description: "A test"}, result[:parsed])
  end

  test "should handle JSON parsing errors gracefully" do
    mock_response = create_mock_response("Invalid JSON")

    @mock_completions.stubs(:create).returns(mock_response)

    assert_raises(JSON::ParserError) do
      @strategy.send_message!(
        ai_chat: @ai_chat,
        content: @content,
        response_format: @response_format,
        schema: nil
      )
    end
  end

  test "should handle OpenAI API errors" do
    @mock_completions.stubs(:create).raises(StandardError.new("API Error"))

    assert_raises(StandardError) do
      @strategy.send_message!(
        ai_chat: @ai_chat,
        content: @content,
        response_format: @response_format,
        schema: nil
      )
    end
  end

  test "should parse response with symbolized keys" do
    mock_response = create_mock_response('{"name": "Test", "active": true}')

    @mock_completions.stubs(:create).returns(mock_response)

    result = @strategy.send_message!(
      ai_chat: @ai_chat,
      content: @content,
      response_format: @response_format,
      schema: nil
    )

    assert_equal({name: "Test", active: true}, result[:parsed])
  end

  test "should handle empty response content" do
    mock_response = create_mock_response("")

    @mock_completions.stubs(:create).returns(mock_response)

    result = @strategy.send_message!(
      ai_chat: @ai_chat,
      content: @content,
      response_format: @response_format,
      schema: nil
    )

    assert_equal "", result[:content]
    assert_equal({}, result[:parsed])
  end

  test "should handle nil response content" do
    mock_response = create_mock_response(nil)

    @mock_completions.stubs(:create).returns(mock_response)

    result = @strategy.send_message!(
      ai_chat: @ai_chat,
      content: @content,
      response_format: @response_format,
      schema: nil
    )

    assert_nil result[:content]
    assert_equal({}, result[:parsed])
  end

  test "should allow easy client stubbing for testing" do
    # This demonstrates how the refactoring makes it easier to stub the client
    # for testing purposes - you can now easily replace the client behavior
    # without having to stub the global OpenAI::Client.new

    different_mock_client = mock
    different_mock_chat = mock
    different_mock_completions = mock

    @strategy.stubs(:client).returns(different_mock_client)
    different_mock_client.stubs(:chat).returns(different_mock_chat)
    different_mock_chat.stubs(:completions).returns(different_mock_completions)

    mock_response = create_mock_response('{"test": "different_client"}')
    different_mock_completions.expects(:create).returns(mock_response)

    result = @strategy.send_message!(
      ai_chat: @ai_chat,
      content: @content,
      response_format: nil,
      schema: nil
    )

    assert_equal '{"test": "different_client"}', result[:content]
    assert_equal({test: "different_client"}, result[:parsed])
  end

  private

  def create_mock_response(content)
    mock_choice = mock
    mock_message = mock
    mock_response = mock

    mock_message.stubs(:content).returns(content)
    mock_choice.stubs(:message).returns(mock_message)

    usage_hash = {prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}
    mock_response.stubs(:choices).returns([mock_choice])
    mock_response.stubs(:id).returns("chatcmpl-123")
    mock_response.stubs(:model).returns("gpt-4")
    mock_response.stubs(:usage).returns(usage_hash)

    mock_response
  end
end
