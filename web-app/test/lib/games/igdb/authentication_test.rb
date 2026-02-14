# frozen_string_literal: true

require "test_helper"

class Games::Igdb::AuthenticationTest < ActiveSupport::TestCase
  def setup
    @original_client_id = ENV["TWITCH_API_CLIENT_ID"]
    @original_client_secret = ENV["TWITCH_API_CLIENT_SECRET"]
    ENV["TWITCH_API_CLIENT_ID"] = "test_client_id"
    ENV["TWITCH_API_CLIENT_SECRET"] = "test_client_secret"

    @config = Games::Igdb::Configuration.new
    @auth = Games::Igdb::Authentication.new(@config)
  end

  def teardown
    ENV["TWITCH_API_CLIENT_ID"] = @original_client_id
    ENV["TWITCH_API_CLIENT_SECRET"] = @original_client_secret
  end

  test "obtains access token from Twitch" do
    stub_successful_token_request

    token = @auth.access_token

    assert_equal "test_access_token", token
  end

  test "caches token on subsequent calls" do
    stub_successful_token_request

    token1 = @auth.access_token
    token2 = @auth.access_token

    assert_equal token1, token2
  end

  test "token_expired? returns true when no token" do
    assert @auth.token_expired?
  end

  test "token_expired? returns false after obtaining token" do
    stub_successful_token_request
    @auth.access_token

    refute @auth.token_expired?
  end

  test "refreshes token when within 5 minutes of expiry" do
    # First request - short-lived token (4 minutes)
    stub_token_request_with_expiry(240)

    @auth.access_token

    assert @auth.token_expired?
  end

  test "raises AuthenticationError on failed token request" do
    stub_failed_token_request(401)

    assert_raises(Games::Igdb::Exceptions::AuthenticationError) do
      @auth.access_token
    end
  end

  test "raises AuthenticationError on invalid JSON response" do
    mock_response = mock("response")
    mock_response.stubs(:status).returns(200)
    mock_response.stubs(:body).returns("not json")

    mock_connection = mock("connection")
    mock_connection.stubs(:post).yields(stub_request).returns(mock_response)
    mock_connection.stubs(:options).returns(OpenStruct.new(timeout: nil, open_timeout: nil))

    Faraday.stubs(:new).returns(mock_connection)

    assert_raises(Games::Igdb::Exceptions::AuthenticationError) do
      @auth.access_token
    end
  end

  test "raises AuthenticationError on network failure" do
    mock_connection = mock("connection")
    mock_connection.stubs(:post).raises(Faraday::ConnectionFailed.new("connection refused"))
    mock_connection.stubs(:options).returns(OpenStruct.new(timeout: nil, open_timeout: nil))

    Faraday.stubs(:new).returns(mock_connection)

    assert_raises(Games::Igdb::Exceptions::AuthenticationError) do
      @auth.access_token
    end
  end

  private

  def stub_successful_token_request
    stub_token_request_with_expiry(5_587_808)
  end

  def stub_token_request_with_expiry(expires_in)
    mock_response = mock("response")
    mock_response.stubs(:status).returns(200)
    mock_response.stubs(:body).returns({
      access_token: "test_access_token",
      expires_in: expires_in,
      token_type: "bearer"
    }.to_json)

    mock_connection = mock("connection")
    mock_connection.stubs(:post).yields(stub_request).returns(mock_response)
    mock_connection.stubs(:options).returns(OpenStruct.new(timeout: nil, open_timeout: nil))

    Faraday.stubs(:new).returns(mock_connection)
  end

  def stub_failed_token_request(status)
    mock_response = mock("response")
    mock_response.stubs(:status).returns(status)
    mock_response.stubs(:body).returns('{"error": "unauthorized"}')

    mock_connection = mock("connection")
    mock_connection.stubs(:post).yields(stub_request).returns(mock_response)
    mock_connection.stubs(:options).returns(OpenStruct.new(timeout: nil, open_timeout: nil))

    Faraday.stubs(:new).returns(mock_connection)
  end

  def stub_request
    OpenStruct.new(params: {}, headers: {}, body: nil)
  end
end
