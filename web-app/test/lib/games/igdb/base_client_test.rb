# frozen_string_literal: true

require "test_helper"
require "ostruct"

class Games::Igdb::BaseClientTest < ActiveSupport::TestCase
  def setup
    @original_client_id = ENV["TWITCH_API_CLIENT_ID"]
    @original_client_secret = ENV["TWITCH_API_CLIENT_SECRET"]
    ENV["TWITCH_API_CLIENT_ID"] = "test_client_id"
    ENV["TWITCH_API_CLIENT_SECRET"] = "test_client_secret"

    @config = Games::Igdb::Configuration.new

    @mock_auth = mock("authentication")
    @mock_auth.stubs(:access_token).returns("test_token")

    @mock_rate_limiter = mock("rate_limiter")
    @mock_rate_limiter.stubs(:wait!)

    @client = Games::Igdb::BaseClient.new(@config)
    @client.stubs(:authentication).returns(@mock_auth)
    @client.instance_variable_set(:@rate_limiter, @mock_rate_limiter)
  end

  def teardown
    ENV["TWITCH_API_CLIENT_ID"] = @original_client_id
    ENV["TWITCH_API_CLIENT_SECRET"] = @original_client_secret
  end

  test "initializes with default configuration" do
    client = Games::Igdb::BaseClient.new
    assert_instance_of Games::Igdb::Configuration, client.config
  end

  test "initializes with custom configuration" do
    client = Games::Igdb::BaseClient.new(@config)
    assert_equal @config, client.config
  end

  test "post sends request with correct headers and body" do
    mock_response = OpenStruct.new(
      status: 200,
      body: '[{"id": 1025, "name": "Zelda"}]'
    )

    mock_connection = mock("connection")
    mock_connection.expects(:post).with("games").yields(stub_request_obj).returns(mock_response)
    @client.instance_variable_set(:@connection, mock_connection)

    result = @client.post("games", "fields name; search \"zelda\";")

    assert result[:success]
    assert_equal [{"id" => 1025, "name" => "Zelda"}], result[:data]
  end

  test "post returns structured response with metadata" do
    mock_response = OpenStruct.new(
      status: 200,
      body: '[{"id": 1}]'
    )

    mock_connection = mock("connection")
    mock_connection.expects(:post).yields(stub_request_obj).returns(mock_response)
    @client.instance_variable_set(:@connection, mock_connection)

    result = @client.post("games", "fields name;")

    assert result[:success]
    assert_empty result[:errors]
    assert_equal "games", result[:metadata][:endpoint]
    assert_equal "fields name;", result[:metadata][:query]
    assert_equal 200, result[:metadata][:status_code]
    assert result[:metadata][:response_time].is_a?(Float)
  end

  test "post calls rate limiter before each request" do
    mock_response = OpenStruct.new(status: 200, body: "[]")
    mock_connection = mock("connection")
    mock_connection.stubs(:post).yields(stub_request_obj).returns(mock_response)
    @client.instance_variable_set(:@connection, mock_connection)

    @mock_rate_limiter.expects(:wait!).once

    @client.post("games", "fields name;")
  end

  test "raises BadRequestError on 400" do
    mock_response = OpenStruct.new(status: 400, body: "Bad Request")
    mock_connection = mock("connection")
    mock_connection.stubs(:post).yields(stub_request_obj).returns(mock_response)
    @client.instance_variable_set(:@connection, mock_connection)

    assert_raises(Games::Igdb::Exceptions::BadRequestError) do
      @client.post("games", "invalid")
    end
  end

  test "raises NotFoundError on 404" do
    mock_response = OpenStruct.new(status: 404, body: "Not Found")
    mock_connection = mock("connection")
    mock_connection.stubs(:post).yields(stub_request_obj).returns(mock_response)
    @client.instance_variable_set(:@connection, mock_connection)

    assert_raises(Games::Igdb::Exceptions::NotFoundError) do
      @client.post("nonexistent", "fields name;")
    end
  end

  test "raises ServerError on 500" do
    mock_response = OpenStruct.new(status: 500, body: "Server Error")
    mock_connection = mock("connection")
    mock_connection.stubs(:post).yields(stub_request_obj).returns(mock_response)
    @client.instance_variable_set(:@connection, mock_connection)

    assert_raises(Games::Igdb::Exceptions::ServerError) do
      @client.post("games", "fields name;")
    end
  end

  test "wraps Faraday timeout in TimeoutError" do
    mock_connection = mock("connection")
    mock_connection.stubs(:post).raises(Faraday::TimeoutError.new("timeout"))
    @client.instance_variable_set(:@connection, mock_connection)

    error = assert_raises(Games::Igdb::Exceptions::TimeoutError) do
      @client.post("games", "fields name;")
    end
    assert_match(/timed out/, error.message)
  end

  test "wraps Faraday connection error in NetworkError" do
    mock_connection = mock("connection")
    mock_connection.stubs(:post).raises(Faraday::ConnectionFailed.new("refused"))
    @client.instance_variable_set(:@connection, mock_connection)

    error = assert_raises(Games::Igdb::Exceptions::NetworkError) do
      @client.post("games", "fields name;")
    end
    assert_match(/Connection failed/, error.message)
  end

  test "raises ParseError on invalid JSON response" do
    mock_response = OpenStruct.new(status: 200, body: "not json")
    mock_connection = mock("connection")
    mock_connection.stubs(:post).yields(stub_request_obj).returns(mock_response)
    @client.instance_variable_set(:@connection, mock_connection)

    assert_raises(Games::Igdb::Exceptions::ParseError) do
      @client.post("games", "fields name;")
    end
  end

  test "retries on 401 with token refresh" do
    unauthorized_response = OpenStruct.new(status: 401, body: "Unauthorized")
    success_response = OpenStruct.new(status: 200, body: '[{"id": 1}]')

    mock_connection = mock("connection")
    # First call returns 401, second (retry) returns 200
    mock_connection.stubs(:post).yields(stub_request_obj)
      .returns(unauthorized_response).then.returns(success_response)
    @client.instance_variable_set(:@connection, mock_connection)

    @mock_auth.expects(:refresh_token!).once

    result = @client.post("games", "fields name;")
    assert result[:success]
  end

  test "raises UnauthorizedError if retry also fails with 401" do
    unauthorized_response = OpenStruct.new(status: 401, body: "Unauthorized")

    mock_connection = mock("connection")
    mock_connection.stubs(:post).yields(stub_request_obj).returns(unauthorized_response)
    @client.instance_variable_set(:@connection, mock_connection)

    @mock_auth.expects(:refresh_token!).once

    assert_raises(Games::Igdb::Exceptions::UnauthorizedError) do
      @client.post("games", "fields name;")
    end
  end

  private

  def stub_request_obj
    OpenStruct.new(headers: {}, body: nil, params: {})
  end
end
