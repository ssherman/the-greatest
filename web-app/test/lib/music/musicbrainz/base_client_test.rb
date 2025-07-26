# frozen_string_literal: true

require "test_helper"
require "ostruct"

class Music::Musicbrainz::BaseClientTest < ActiveSupport::TestCase
  def setup
    @config = Music::Musicbrainz::Configuration.new
    @config.base_url = "http://localhost:5000"
    @client = Music::Musicbrainz::BaseClient.new(@config)
  end

  test "initializes with default configuration" do
    client = Music::Musicbrainz::BaseClient.new
    assert_instance_of Music::Musicbrainz::Configuration, client.config
  end

  test "initializes with custom configuration" do
    client = Music::Musicbrainz::BaseClient.new(@config)
    assert_equal @config, client.config
  end

  test "builds connection with correct base URL" do
    assert_equal "http://localhost:5000/ws/2", @client.connection.url_prefix.to_s
  end

  test "builds params with JSON format" do
    params = @client.send(:build_params, { query: "test" })
    
    assert_equal "json", params[:fmt]
    assert_equal "test", params[:query]
  end

  test "builds params merges additional parameters" do
    params = @client.send(:build_params, { query: "test", limit: 10 })
    
    assert_equal "json", params[:fmt]
    assert_equal "test", params[:query]
    assert_equal 10, params[:limit]
  end

  test "parse_success_response returns structured response" do
    mock_response = OpenStruct.new(
      body: '{"artists": [{"name": "Test Artist"}]}',
      status: 200
    )
    
    start_time = Time.current
    result = @client.send(:parse_success_response, mock_response, "artist", { query: "test" }, Time.current - start_time)
    
    assert result[:success]
    assert_equal({ "artists" => [{ "name" => "Test Artist" }] }, result[:data])
    assert_empty result[:errors]
    assert_equal "artist", result[:metadata][:endpoint]
    assert_equal "test", result[:metadata][:query]
    assert_equal 200, result[:metadata][:status_code]
    assert result[:metadata][:response_time].is_a?(Float)
  end

  test "parse_success_response handles JSON parse errors" do
    mock_response = OpenStruct.new(
      body: "invalid json",
      status: 200
    )
    
    start_time = Time.current
    
    assert_raises(Music::Musicbrainz::ParseError) do
      @client.send(:parse_success_response, mock_response, "artist", { query: "test" }, Time.current - start_time)
    end
  end

  test "parse_response handles different HTTP status codes" do
    start_time = Time.current
    
    # Test 400 Bad Request
    mock_400 = OpenStruct.new(status: 400, body: "Bad Request")
    assert_raises(Music::Musicbrainz::BadRequestError) do
      @client.send(:parse_response, mock_400, "artist", {}, start_time)
    end
    
    # Test 404 Not Found
    mock_404 = OpenStruct.new(status: 404, body: "Not Found")
    assert_raises(Music::Musicbrainz::NotFoundError) do
      @client.send(:parse_response, mock_404, "artist", {}, start_time)
    end
    
    # Test 500 Server Error
    mock_500 = OpenStruct.new(status: 500, body: "Server Error")
    assert_raises(Music::Musicbrainz::ServerError) do
      @client.send(:parse_response, mock_500, "artist", {}, start_time)
    end
  end

  test "connection has correct adapter configured" do
    # Check that default adapter is configured
    assert_not_nil @client.connection.adapter
  end

  test "connection has correct timeouts configured" do
    assert_equal @config.timeout, @client.connection.options.timeout
    assert_equal @config.open_timeout, @client.connection.options.open_timeout
  end
end 