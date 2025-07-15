require "test_helper"

class Services::Ai::Providers::BaseStrategyTest < ActiveSupport::TestCase
  def setup
    @strategy = Services::Ai::Providers::BaseStrategy.new
    @ai_chat = ai_chats(:general_chat)
    @content = "Test message content"
  end

  test "should raise NotImplementedError for client method" do
    assert_raises(NotImplementedError, "Subclasses must implement #client") do
      @strategy.send(:client)
    end
  end

  test "should raise NotImplementedError for make_api_call method" do
    assert_raises(NotImplementedError, "Subclasses must implement #make_api_call") do
      @strategy.send(:make_api_call, {})
    end
  end

  test "should raise NotImplementedError for format_response method" do
    assert_raises(NotImplementedError, "Subclasses must implement #format_response") do
      @strategy.send(:format_response, {}, nil)
    end
  end

  test "should provide default build_parameters implementation" do
    parameters = @strategy.send(:build_parameters,
      model: "gpt-4",
      messages: [{role: "user", content: "Hello"}],
      temperature: 0.5,
      response_format: nil,
      schema: nil)

    expected_parameters = {
      model: "gpt-4",
      messages: [{role: "user", content: "Hello"}],
      temperature: 0.5
    }

    assert_equal expected_parameters, parameters
  end

  test "should provide common parse_response implementation" do
    json_content = '{"key": "value", "number": 42}'
    result = @strategy.send(:parse_response, json_content, nil)

    assert_equal({key: "value", number: 42}, result)
  end

  test "should handle empty content in parse_response" do
    assert_equal({}, @strategy.send(:parse_response, "", nil))
    assert_equal({}, @strategy.send(:parse_response, nil, nil))
  end

  test "should raise JSON::ParserError for invalid JSON in parse_response" do
    assert_raises(JSON::ParserError) do
      @strategy.send(:parse_response, "invalid json", nil)
    end
  end
end
