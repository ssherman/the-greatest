# frozen_string_literal: true

require "test_helper"

class Music::Musicbrainz::Search::ArtistSearchTest < ActiveSupport::TestCase
  def setup
    @mock_client = mock('client')
    @search = Music::Musicbrainz::Search::ArtistSearch.new(@mock_client)
  end

  test "entity_type returns artist" do
    assert_equal "artist", @search.entity_type
  end

  test "mbid_field returns arid" do
    assert_equal "arid", @search.mbid_field
  end

  test "available_fields returns correct artist fields" do
    expected_fields = %w[
      name arid alias tag type country gender
      begin end area sortname comment
    ]
    assert_equal expected_fields, @search.available_fields
  end

  test "search_by_name searches by name field" do
    @mock_client.expects(:get)
      .with("artist", { query: 'name:The\\ Beatles' })
      .returns(successful_artist_response)
    
    result = @search.search_by_name("The Beatles")
    
    assert result[:success]
    assert_equal 1, result[:data]["count"]
  end

  test "search_by_alias searches by alias field" do
    @mock_client.expects(:get)
      .with("artist", { query: 'alias:Fab\\ Four' })
      .returns(successful_artist_response)
    
    result = @search.search_by_alias("Fab Four")
    
    assert result[:success]
  end

  test "search_by_tag searches by tag field" do
    @mock_client.expects(:get)
      .with("artist", { query: 'tag:rock' })
      .returns(successful_artist_response)
    
    result = @search.search_by_tag("rock")
    
    assert result[:success]
  end

  test "search_by_type searches by type field" do
    @mock_client.expects(:get)
      .with("artist", { query: 'type:group' })
      .returns(successful_artist_response)
    
    result = @search.search_by_type("group")
    
    assert result[:success]
  end

  test "search_by_country searches by country field" do
    @mock_client.expects(:get)
      .with("artist", { query: 'country:GB' })
      .returns(successful_artist_response)
    
    result = @search.search_by_country("GB")
    
    assert result[:success]
  end

  test "search_by_gender searches by gender field" do
    @mock_client.expects(:get)
      .with("artist", { query: 'gender:male' })
      .returns(successful_artist_response)
    
    result = @search.search_by_gender("male")
    
    assert result[:success]
  end

  test "search performs general search with custom query" do
    @mock_client.expects(:get)
      .with("artist", { query: 'name:Beatles AND country:GB' })
      .returns(successful_artist_response)
    
    result = @search.search("name:Beatles AND country:GB")
    
    assert result[:success]
  end

  test "search includes pagination options" do
    @mock_client.expects(:get)
      .with("artist", { query: 'name:Beatles', limit: 10, offset: 20 })
      .returns(successful_artist_response)
    
    result = @search.search("name:Beatles", limit: 10, offset: 20)
    
    assert result[:success]
  end

  test "search_with_criteria builds complex queries" do
    criteria = {
      name: "The Beatles",
      country: "GB",
      type: "group"
    }
    
    expected_query = 'name:The\\ Beatles AND country:GB AND type:group'
    
    @mock_client.expects(:get)
      .with("artist", { query: expected_query })
      .returns(successful_artist_response)
    
    result = @search.search_with_criteria(criteria)
    
    assert result[:success]
  end

  test "search_with_criteria skips blank values" do
    criteria = {
      name: "The Beatles",
      country: "",
      type: nil
    }
    
    @mock_client.expects(:get)
      .with("artist", { query: 'name:The\\ Beatles' })
      .returns(successful_artist_response)
    
    result = @search.search_with_criteria(criteria)
    
    assert result[:success]
  end

  test "search_with_criteria raises error for invalid fields" do
    criteria = { invalid_field: "value" }
    
    assert_raises(Music::Musicbrainz::QueryError) do
      @search.search_with_criteria(criteria)
    end
  end

  test "search_with_criteria raises error when no criteria provided" do
    criteria = { name: "", country: nil }
    
    assert_raises(Music::Musicbrainz::QueryError) do
      @search.search_with_criteria(criteria)
    end
  end

  test "returns raw API response data without processing" do
    @mock_client.expects(:get)
      .with("artist", { query: 'name:The\\ Beatles' })
      .returns(successful_artist_response)
    
    result = @search.search_by_name("The Beatles")
    
    assert result[:success]
    # Should return raw data structure from API
    assert_equal "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d", result[:data]["artists"].first["id"]
    assert_equal "The Beatles", result[:data]["artists"].first["name"]
  end

  test "search handles API errors gracefully" do
    @mock_client.expects(:get)
      .raises(Music::Musicbrainz::NetworkError.new("Connection failed"))
    
    result = @search.search("name:Beatles")
    
    refute result[:success]
    assert_includes result[:errors], "Connection failed"
    assert_equal "artist", result[:metadata][:entity_type]
  end

  test "find_by_mbid uses correct MBID field" do
    valid_mbid = "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"
    
    @mock_client.expects(:get)
      .with("artist", { query: "arid:b10bbbfc\\-cf9e\\-42e0\\-be17\\-e2c3e1d2600d" })
      .returns(successful_artist_response)
    
    result = @search.find_by_mbid(valid_mbid)
    
    assert result[:success]
  end

  private

  def successful_artist_response
    {
      success: true,
      data: {
        "count" => 1,
        "offset" => 0,
        "artists" => [
          {
            "id" => "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d",
            "name" => "The Beatles",
            "sort-name" => "Beatles, The",
            "type" => "Group",
            "score" => "100"
          }
        ]
      },
      errors: [],
      metadata: {
        endpoint: "artist",
        response_time: 0.123
      }
    }
  end
end 