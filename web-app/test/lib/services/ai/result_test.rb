require "test_helper"

class Services::Ai::ResultTest < ActiveSupport::TestCase
  def setup
    @mock_chat = mock
    @data = {test: "data"}
  end

  test "should create successful result" do
    result = Services::Ai::Result.new(
      success: true,
      data: @data,
      ai_chat: @mock_chat
    )

    assert result.success?
    assert_equal @data, result.data
    assert_equal @mock_chat, result.ai_chat
    assert_nil result.error
  end

  test "should create error result" do
    error_message = "Something went wrong"
    result = Services::Ai::Result.new(
      success: false,
      error: error_message
    )

    refute result.success?
    assert_equal error_message, result.error
    assert_nil result.data
    assert_nil result.ai_chat
  end

  test "should handle nil data" do
    result = Services::Ai::Result.new(
      success: true,
      data: nil,
      ai_chat: @mock_chat
    )

    assert result.success?
    assert_nil result.data
    assert_equal @mock_chat, result.ai_chat
  end

  test "should handle nil ai_chat" do
    result = Services::Ai::Result.new(
      success: true,
      data: @data,
      ai_chat: nil
    )

    assert result.success?
    assert_equal @data, result.data
    assert_nil result.ai_chat
  end

  test "should handle complex data structures" do
    complex_data = {
      nested: {
        array: [1, 2, 3],
        string: "test",
        boolean: true,
        number: 42
      }
    }

    result = Services::Ai::Result.new(
      success: true,
      data: complex_data,
      ai_chat: @mock_chat
    )

    assert result.success?
    assert_equal complex_data, result.data
    assert_equal [1, 2, 3], result.data[:nested][:array]
    assert_equal "test", result.data[:nested][:string]
    assert result.data[:nested][:boolean]
    assert_equal 42, result.data[:nested][:number]
  end

  test "should handle empty data" do
    result = Services::Ai::Result.new(
      success: true,
      data: {},
      ai_chat: @mock_chat
    )

    assert result.success?
    assert_equal({}, result.data)
    assert_equal @mock_chat, result.ai_chat
  end

  test "should handle empty error message" do
    result = Services::Ai::Result.new(
      success: false,
      error: ""
    )

    refute result.success?
    assert_equal "", result.error
    assert_nil result.data
    assert_nil result.ai_chat
  end

  test "should handle nil error message" do
    result = Services::Ai::Result.new(
      success: false,
      error: nil
    )

    refute result.success?
    assert_nil result.error
    assert_nil result.data
    assert_nil result.ai_chat
  end

  test "should be comparable" do
    result1 = Services::Ai::Result.new(success: true, data: @data)
    result2 = Services::Ai::Result.new(success: true, data: @data)
    result3 = Services::Ai::Result.new(success: false, error: "error")

    assert_equal result1, result2
    refute_equal result1, result3
  end

  test "should have readable string representation" do
    result = Services::Ai::Result.new(
      success: true,
      data: @data,
      ai_chat: @mock_chat
    )

    string_rep = result.to_s
    assert_includes string_rep, "Services::Ai::Result"
    assert_includes string_rep, "success: true"
  end

  test "should handle ai_chat with methods" do
    mock_chat_with_methods = mock
    mock_chat_with_methods.stubs(:id).returns(123)
    mock_chat_with_methods.stubs(:model).returns("gpt-4")

    result = Services::Ai::Result.new(
      success: true,
      data: @data,
      ai_chat: mock_chat_with_methods
    )

    assert result.success?
    assert_equal @data, result.data
    assert_equal mock_chat_with_methods, result.ai_chat
    assert_equal 123, result.ai_chat.id
    assert_equal "gpt-4", result.ai_chat.model
  end
end
