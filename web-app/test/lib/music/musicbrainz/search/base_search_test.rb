# frozen_string_literal: true

require "test_helper"

class Music::Musicbrainz::Search::BaseSearchTest < ActiveSupport::TestCase
  # Create a test subclass to test the base functionality
  class TestSearch < Music::Musicbrainz::Search::BaseSearch
    def entity_type
      "test-entity"
    end

    def mbid_field
      "tid"
    end

    def available_fields
      %w[name tid alias]
    end

    def search(query, options = {})
      params = build_search_params(query, options)
      {success: true, data: {query: query}, metadata: {params: params}}
    end
  end

  def setup
    @mock_client = mock("client")
    @search = TestSearch.new(@mock_client)
  end

  test "initializes with provided client" do
    assert_equal @mock_client, @search.client
  end

  test "initializes with default client when none provided" do
    search = TestSearch.new
    assert_instance_of Music::Musicbrainz::BaseClient, search.client
  end

  test "entity_type returns correct value" do
    assert_equal "test-entity", @search.entity_type
  end

  test "mbid_field returns correct value" do
    assert_equal "tid", @search.mbid_field
  end

  test "available_fields returns correct array" do
    assert_equal %w[name tid alias], @search.available_fields
  end

  test "build_field_query escapes and formats query" do
    query = @search.send(:build_field_query, "name", "test value")
    assert_equal 'name:test\\ value', query
  end

  test "build_field_query escapes basic Lucene characters" do
    query = @search.send(:build_field_query, "name", "test value-with:special")
    assert_equal 'name:test\\ value\\-with\\:special', query
  end

  test "build_search_params includes basic parameters" do
    params = @search.send(:build_search_params, "test query", {})

    assert_equal "test query", params[:query]
    refute params.key?(:limit)
    refute params.key?(:offset)
  end

  test "build_search_params includes optional parameters" do
    options = {limit: 10, offset: 20, dismax: true}
    params = @search.send(:build_search_params, "test query", options)

    assert_equal "test query", params[:query]
    assert_equal 10, params[:limit]
    assert_equal 20, params[:offset]
    assert_equal true, params[:dismax]
  end

  test "validate_mbid! accepts valid MBID" do
    valid_mbid = "550e8400-e29b-41d4-a716-446655440000"

    assert_nothing_raised do
      @search.send(:validate_mbid!, valid_mbid)
    end
  end

  test "validate_mbid! rejects invalid MBID format" do
    invalid_mbids = [
      "not-a-uuid",
      "550e8400-e29b-41d4-a716",
      "550e8400-e29b-41d4-a716-44665544000g",
      ""
    ]

    invalid_mbids.each do |mbid|
      assert_raises(Music::Musicbrainz::Exceptions::QueryError) do
        @search.send(:validate_mbid!, mbid)
      end
    end
  end

  test "validate_search_params! accepts valid parameters" do
    valid_params = {query: "test", limit: 50, offset: 10}

    assert_nothing_raised do
      @search.send(:validate_search_params!, valid_params)
    end
  end

  test "validate_search_params! rejects invalid limit" do
    assert_raises(Music::Musicbrainz::Exceptions::QueryError) do
      @search.send(:validate_search_params!, {query: "test", limit: 0})
    end

    assert_raises(Music::Musicbrainz::Exceptions::QueryError) do
      @search.send(:validate_search_params!, {query: "test", limit: 101})
    end
  end

  test "validate_search_params! rejects negative offset" do
    assert_raises(Music::Musicbrainz::Exceptions::QueryError) do
      @search.send(:validate_search_params!, {query: "test", offset: -1})
    end
  end

  test "validate_search_params! rejects blank query" do
    assert_raises(Music::Musicbrainz::Exceptions::QueryError) do
      @search.send(:validate_search_params!, {query: ""})
    end

    assert_raises(Music::Musicbrainz::Exceptions::QueryError) do
      @search.send(:validate_search_params!, {query: nil})
    end
  end

  test "escape_lucene_query escapes basic special characters" do
    special_chars = {
      "test query" => 'test\\ query',
      "test:query" => 'test\\:query',
      "test-query" => 'test\\-query',
      'test\\query' => 'test\\\\query'
    }

    special_chars.each do |input, expected|
      result = @search.send(:escape_lucene_query, input)
      assert_equal expected, result, "Failed to escape: #{input}"
    end
  end

  test "find_by_mbid validates and searches by MBID" do
    valid_mbid = "550e8400-e29b-41d4-a716-446655440000"

    @mock_client.expects(:get)
      .with("test-entity", {query: "tid:550e8400\\-e29b\\-41d4\\-a716\\-446655440000"})
      .returns({success: true, data: {test: "result"}})

    result = @search.find_by_mbid(valid_mbid)

    assert result[:success]
  end

  test "handle_search_error returns structured error response" do
    error = Music::Musicbrainz::Exceptions::NetworkError.new("Connection failed")
    query = "test query"
    options = {limit: 10}

    result = @search.send(:handle_search_error, error, query, options)

    refute result[:success]
    assert_nil result[:data]
    assert_equal ["Connection failed"], result[:errors]
    assert_equal "test-entity", result[:metadata][:entity_type]
    assert_equal query, result[:metadata][:query]
    assert_equal options, result[:metadata][:options]
    assert_equal "Music::Musicbrainz::Exceptions::NetworkError", result[:metadata][:error_type]
  end

  test "process_search_response returns response unchanged for successful responses" do
    response = {success: true, data: {test: "data"}}
    result = @search.send(:process_search_response, response)

    assert_equal response, result
  end

  test "process_search_response returns response unchanged for failed responses" do
    response = {success: false, errors: ["Error"]}
    result = @search.send(:process_search_response, response)

    assert_equal response, result
  end
end
