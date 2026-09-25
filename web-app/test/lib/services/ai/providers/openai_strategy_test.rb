require "test_helper"

class Services::Ai::Providers::OpenaiStrategyTest < ActiveSupport::TestCase
  def setup
    @strategy = Services::Ai::Providers::OpenaiStrategy.new
    @ai_chat = ai_chats(:general_chat)
    @content = "Test message content"
    @response_format = {type: "json_object"}

    # Mock the client for Responses API
    @mock_client = mock
    @mock_responses = mock
    @strategy.stubs(:client).returns(@mock_client)
    @mock_client.stubs(:responses).returns(@mock_responses)
  end

  test "should have correct capabilities" do
    expected_capabilities = %i[json_mode json_schema function_calls]
    assert_equal expected_capabilities, @strategy.capabilities
  end

  test "should have correct default model" do
    assert_equal "gpt-6-luna", @strategy.default_model
  end

  test "should have correct provider key" do
    assert_equal :openai, @strategy.provider_key
  end

  test "should send message with basic parameters" do
    mock_response = create_mock_response({message: "Hello, world!"})

    # Note: Responses API uses array format when there are multiple messages
    expected_input = [
      {role: "user", content: "Hello"},
      {role: "user", content: @content}
    ]

    @mock_responses.expects(:create).with(
      {
        model: @ai_chat.model,
        input: expected_input,
        temperature: @ai_chat.temperature.to_f,
        service_tier: "flex"
      }
    ).returns(mock_response)

    result = @strategy.send_message!(
      ai_chat: @ai_chat,
      content: @content,
      response_format: nil,
      schema: nil
    )

    assert_equal '{"message":"Hello, world!"}', result[:content]
    assert_equal({message: "Hello, world!"}, result[:parsed])
    assert_equal "resp-123", result[:id]
    assert_equal "gpt-5-mini", result[:model]
    assert_equal({prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}, result[:usage])
  end

  test "should send message with reasoning parameter when provided" do
    mock_response = create_mock_response({key: "value"})

    expected_input = [
      {role: "user", content: "Hello"},
      {role: "user", content: @content}
    ]

    @mock_responses.expects(:create).with(
      {
        model: @ai_chat.model,
        input: expected_input,
        temperature: @ai_chat.temperature.to_f,
        service_tier: "flex",
        reasoning: {effort: "low"}
      }
    ).returns(mock_response)

    result = @strategy.send_message!(
      ai_chat: @ai_chat,
      content: @content,
      response_format: nil,
      schema: nil,
      reasoning: {effort: "low"}
    )

    assert_equal '{"key":"value"}', result[:content]
    assert_equal({key: "value"}, result[:parsed])
  end

  test "should send message with JSON schema when provided" do
    schema_class = Class.new(OpenAI::BaseModel) do
      required :name, String
      required :description, String, nil?: true
    end

    mock_response = create_mock_response({name: "Test", description: "A test"})

    expected_input = [
      {role: "user", content: "Hello"},
      {role: "user", content: @content}
    ]

    @mock_responses.expects(:create).with(
      {
        model: @ai_chat.model,
        input: expected_input,
        temperature: @ai_chat.temperature.to_f,
        service_tier: "flex",
        text: schema_class
      }
    ).returns(mock_response)

    result = @strategy.send_message!(
      ai_chat: @ai_chat,
      content: @content,
      response_format: nil,
      schema: schema_class
    )

    assert_equal '{"name":"Test","description":"A test"}', result[:content]
    assert_equal({name: "Test", description: "A test"}, result[:parsed])
  end

  test "should extract system message as instructions and use string input" do
    # Mock chat with system message
    chat_with_system = mock
    chat_with_system.stubs(:messages).returns([
      {role: "system", content: "You are a helpful assistant.", timestamp: "2024-01-01T10:00:00Z"}
    ])
    chat_with_system.stubs(:model).returns("gpt-4")
    chat_with_system.stubs(:temperature).returns(0.7)
    chat_with_system.stubs(:parameters=)
    chat_with_system.stubs(:save!)

    mock_response = create_mock_response({result: "success"})

    # Single user message should be a string, not an array
    @mock_responses.expects(:create).with(
      {
        model: "gpt-4",
        instructions: "You are a helpful assistant.",
        input: @content,  # String, not array
        temperature: 0.7,
        service_tier: "flex"
      }
    ).returns(mock_response)

    @strategy.send_message!(
      ai_chat: chat_with_system,
      content: @content,
      response_format: nil,
      schema: nil
    )
  end

  test "should handle OpenAI API errors" do
    @mock_responses.stubs(:create).raises(StandardError.new("API Error"))

    assert_raises(StandardError) do
      @strategy.send_message!(
        ai_chat: @ai_chat,
        content: @content,
        response_format: nil,
        schema: nil
      )
    end
  end

  test "should parse response with symbolized keys" do
    mock_response = create_mock_response({name: "Test", active: true})

    @mock_responses.stubs(:create).returns(mock_response)

    result = @strategy.send_message!(
      ai_chat: @ai_chat,
      content: @content,
      response_format: nil,
      schema: nil
    )

    assert_equal({name: "Test", active: true}, result[:parsed])
  end

  test "should allow easy client stubbing for testing" do
    different_mock_client = mock
    different_mock_responses = mock

    @strategy.stubs(:client).returns(different_mock_client)
    different_mock_client.stubs(:responses).returns(different_mock_responses)

    mock_response = create_mock_response({test: "different_client"})
    different_mock_responses.expects(:create).returns(mock_response)

    result = @strategy.send_message!(
      ai_chat: @ai_chat,
      content: @content,
      response_format: nil,
      schema: nil
    )

    assert_equal '{"test":"different_client"}', result[:content]
    assert_equal({test: "different_client"}, result[:parsed])
  end

  test "sends the web_search tool when a task asks for it" do
    mock_response = create_mock_response({ok: true})

    @mock_responses.expects(:create).with(
      {
        model: @ai_chat.model,
        input: [{role: "user", content: "Hello"}, {role: "user", content: @content}],
        temperature: @ai_chat.temperature.to_f,
        service_tier: "flex",
        tools: [{type: "web_search", search_context_size: "low"}]
      }
    ).returns(mock_response)

    @strategy.send_message!(ai_chat: @ai_chat, content: @content, response_format: nil, schema: nil, tools: [:web_search])
  end

  test "forces the tool with tool_choice when asked" do
    mock_response = create_mock_response({ok: true})

    @mock_responses.expects(:create).with(
      has_entries(
        tools: [{type: "web_search", search_context_size: "low"}],
        tool_choice: {type: "web_search"}
      )
    ).returns(mock_response)

    @strategy.send_message!(ai_chat: @ai_chat, content: @content, response_format: nil, schema: nil, tools: [:web_search], force_tool: true)
  end

  test "an unknown tool raises before any request is made" do
    @mock_responses.expects(:create).never

    error = assert_raises(ArgumentError) do
      @strategy.send_message!(ai_chat: @ai_chat, content: @content, response_format: nil, schema: nil, tools: [:teleport])
    end
    assert_match(/Unknown AI tool/, error.message)
  end

  test "returns no citations and zero web search calls for a plain response" do
    @mock_responses.stubs(:create).returns(create_mock_response({ok: true}))

    result = @strategy.send_message!(ai_chat: @ai_chat, content: @content, response_format: nil, schema: nil)

    assert_equal [], result[:citations]
    assert_equal 0, result[:web_search_calls]
  end

  test "extracts url citations, strips utm_source and de-duplicates" do
    annotation_a = mock
    annotation_a.stubs(:type).returns(:url_citation)
    annotation_a.stubs(:url).returns("https://example.org/book")
    annotation_b = mock
    annotation_b.stubs(:type).returns(:url_citation)
    annotation_b.stubs(:url).returns("https://example.org/book?utm_source=openai")
    annotation_c = mock
    annotation_c.stubs(:type).returns(:url_citation)
    annotation_c.stubs(:url).returns("https://example.org/other?page=2&utm_source=openai")
    annotation_string_type = mock
    annotation_string_type.stubs(:type).returns("url_citation")
    annotation_string_type.stubs(:url).returns("https://example.org/string-type")
    file_annotation = mock
    file_annotation.stubs(:type).returns(:file_citation)

    mock_response = create_mock_response(
      {ok: true},
      annotations: [annotation_a, annotation_b, annotation_c, annotation_string_type, file_annotation],
      web_search_calls: 2
    )
    @mock_responses.stubs(:create).returns(mock_response)

    result = @strategy.send_message!(ai_chat: @ai_chat, content: @content, response_format: nil, schema: nil, tools: [:web_search])

    assert_equal(
      ["https://example.org/book", "https://example.org/other?page=2", "https://example.org/string-type"],
      result[:citations]
    )
    assert_equal 2, result[:web_search_calls]
  end

  test "strips utm_source from a non-ASCII URL without raising" do
    annotation = mock
    annotation.stubs(:type).returns(:url_citation)
    annotation.stubs(:url).returns("https://en.wikipedia.org/wiki/Café?utm_source=openai")

    mock_response = create_mock_response({ok: true}, annotations: [annotation])
    @mock_responses.stubs(:create).returns(mock_response)

    result = @strategy.send_message!(ai_chat: @ai_chat, content: @content, response_format: nil, schema: nil, tools: [:web_search])

    assert_equal ["https://en.wikipedia.org/wiki/Café"], result[:citations]
  end

  test "strips only utm_source, preserving other query params and the fragment" do
    annotation = mock
    annotation.stubs(:type).returns(:url_citation)
    annotation.stubs(:url).returns("https://example.org/a?path=/a/b&utm_source=openai#frag")

    mock_response = create_mock_response({ok: true}, annotations: [annotation])
    @mock_responses.stubs(:create).returns(mock_response)

    result = @strategy.send_message!(ai_chat: @ai_chat, content: @content, response_format: nil, schema: nil, tools: [:web_search])

    assert_equal ["https://example.org/a?path=/a/b#frag"], result[:citations]
  end

  private

  def create_mock_response(parsed_data, annotations: nil, web_search_calls: 0)
    mock_content = mock
    mock_content.stubs(:text).returns(parsed_data.to_json)
    mock_content.stubs(:parsed).returns(parsed_data)
    # A content item without annotations (older SDK shapes, or a message with
    # none) must not raise; only stub the method when the test supplies some.
    mock_content.stubs(:annotations).returns(annotations) unless annotations.nil?

    mock_message_item = mock
    mock_message_item.stubs(:type).returns(:message)
    mock_message_item.stubs(:content).returns([mock_content])

    search_items = Array.new(web_search_calls) do
      item = mock
      item.stubs(:type).returns(:web_search_call)
      item
    end

    mock_response = mock
    usage_hash = {prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}
    mock_response.stubs(:output).returns(search_items + [mock_message_item])
    mock_response.stubs(:id).returns("resp-123")
    mock_response.stubs(:model).returns("gpt-5-mini")
    mock_response.stubs(:usage).returns(usage_hash)

    mock_response
  end
end
