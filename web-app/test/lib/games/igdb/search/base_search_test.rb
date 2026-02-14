# frozen_string_literal: true

require "test_helper"

class Games::Igdb::Search::BaseSearchTest < ActiveSupport::TestCase
  class TestSearch < Games::Igdb::Search::BaseSearch
    def endpoint
      "test_entities"
    end

    def default_fields
      %w[name slug]
    end
  end

  def setup
    @mock_client = mock("client")
    @search = TestSearch.new(@mock_client)
  end

  test "initializes with provided client" do
    assert_equal @mock_client, @search.client
  end

  test "endpoint returns correct value" do
    assert_equal "test_entities", @search.endpoint
  end

  test "default_fields returns correct value" do
    assert_equal %w[name slug], @search.default_fields
  end

  test "find_by_id sends correct query" do
    @mock_client.expects(:post)
      .with("test_entities", "fields name, slug; where id = 42;")
      .returns(successful_response)

    result = @search.find_by_id(42)
    assert result[:success]
  end

  test "find_by_id validates id is positive integer" do
    assert_raises(Games::Igdb::Exceptions::QueryError) do
      @search.find_by_id(-1)
    end

    assert_raises(Games::Igdb::Exceptions::QueryError) do
      @search.find_by_id("abc")
    end

    assert_raises(Games::Igdb::Exceptions::QueryError) do
      @search.find_by_id(0)
    end
  end

  test "find_by_id accepts custom fields" do
    @mock_client.expects(:post)
      .with("test_entities", "fields name, rating; where id = 42;")
      .returns(successful_response)

    @search.find_by_id(42, fields: %w[name rating])
  end

  test "find_by_ids sends correct query" do
    @mock_client.expects(:post)
      .with("test_entities", "fields name, slug; where id = (1,2,3);")
      .returns(successful_response)

    result = @search.find_by_ids([1, 2, 3])
    assert result[:success]
  end

  test "find_by_ids validates all ids" do
    assert_raises(Games::Igdb::Exceptions::QueryError) do
      @search.find_by_ids([1, -2, 3])
    end
  end

  test "search sends correct query" do
    @mock_client.expects(:post)
      .with("test_entities", 'fields name, slug; search "zelda"; limit 10;')
      .returns(successful_response)

    result = @search.search("zelda")
    assert result[:success]
  end

  test "search with custom limit and offset" do
    @mock_client.expects(:post)
      .with("test_entities", 'fields name, slug; search "zelda"; limit 25; offset 50;')
      .returns(successful_response)

    @search.search("zelda", limit: 25, offset: 50)
  end

  test "where sends correct query with string condition" do
    @mock_client.expects(:post)
      .with("test_entities", "fields name, slug; where rating > 75; limit 10;")
      .returns(successful_response)

    result = @search.where("rating > 75")
    assert result[:success]
  end

  test "where with sort" do
    @mock_client.expects(:post)
      .with("test_entities", "fields name, slug; where rating > 75; sort rating desc; limit 10;")
      .returns(successful_response)

    @search.where("rating > 75", sort: [:rating, :desc])
  end

  test "all sends correct query" do
    @mock_client.expects(:post)
      .with("test_entities", "fields name, slug; limit 10;")
      .returns(successful_response)

    result = @search.all
    assert result[:success]
  end

  test "all with sort and offset" do
    @mock_client.expects(:post)
      .with("test_entities", "fields name, slug; sort name asc; limit 50; offset 100;")
      .returns(successful_response)

    @search.all(limit: 50, offset: 100, sort: [:name, :asc])
  end

  test "count sends request to count endpoint" do
    @mock_client.expects(:post)
      .with("test_entities/count", "where rating > 75;")
      .returns({success: true, data: {"count" => 42}})

    result = @search.count("rating > 75")
    assert result[:success]
    assert_equal 42, result[:data]["count"]
  end

  test "count without conditions sends fields_all" do
    @mock_client.expects(:post)
      .with("test_entities/count", "fields *;")
      .returns({success: true, data: {"count" => 100}})

    result = @search.count
    assert result[:success]
  end

  test "handles API errors gracefully" do
    @mock_client.expects(:post)
      .raises(Games::Igdb::Exceptions::NetworkError.new("Connection failed"))

    result = @search.search("test")

    refute result[:success]
    assert_includes result[:errors], "Connection failed"
    assert_equal "test_entities", result[:metadata][:endpoint]
    assert_equal "Games::Igdb::Exceptions::NetworkError", result[:metadata][:error_type]
  end

  test "handles empty array response as success" do
    @mock_client.expects(:post)
      .returns({success: true, data: [], errors: [], metadata: {}})

    result = @search.search("nonexistent")
    assert result[:success]
    assert_equal [], result[:data]
  end

  private

  def successful_response
    {
      success: true,
      data: [{"id" => 1, "name" => "Test Entity", "slug" => "test-entity"}],
      errors: [],
      metadata: {endpoint: "test_entities", response_time: 0.123, status_code: 200}
    }
  end
end
