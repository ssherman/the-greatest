# frozen_string_literal: true

require "test_helper"

class Music::Musicbrainz::Search::RecordingSearchTest < ActiveSupport::TestCase
  def setup
    @mock_client = mock("client")
    @search = Music::Musicbrainz::Search::RecordingSearch.new(@mock_client)
  end

  test "entity_type returns recording" do
    assert_equal "recording", @search.entity_type
  end

  test "mbid_field returns rid" do
    assert_equal "rid", @search.mbid_field
  end

  test "available_fields returns correct recording fields" do
    expected_fields = %w[
      title rid arid artist artistname tag type
      country date dur length isrc comment
      release rgid status
    ]
    assert_equal expected_fields, @search.available_fields
  end

  test "search_by_title searches by title field" do
    @mock_client.expects(:get)
      .with("recording", {query: 'title:Come\\ Together'})
      .returns(successful_recording_response)

    result = @search.search_by_title("Come Together")

    assert result[:success]
    assert_equal 1, result[:data]["count"]
  end

  test "search_by_artist_mbid searches by artist MBID" do
    artist_mbid = "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"

    @mock_client.expects(:get)
      .with("recording", {query: "arid:b10bbbfc\\-cf9e\\-42e0\\-be17\\-e2c3e1d2600d"})
      .returns(successful_recording_response)

    result = @search.search_by_artist_mbid(artist_mbid)

    assert result[:success]
  end

  test "search_by_artist_name searches by artist name" do
    @mock_client.expects(:get)
      .with("recording", {query: 'artist:The\\ Beatles'})
      .returns(successful_recording_response)

    result = @search.search_by_artist_name("The Beatles")

    assert result[:success]
  end

  test "search_by_isrc searches by ISRC field" do
    @mock_client.expects(:get)
      .with("recording", {query: "isrc:GBUM71505078"})
      .returns(successful_recording_response)

    result = @search.search_by_isrc("GBUM71505078")

    assert result[:success]
  end

  test "search_by_tag searches by tag field" do
    @mock_client.expects(:get)
      .with("recording", {query: "tag:rock"})
      .returns(successful_recording_response)

    result = @search.search_by_tag("rock")

    assert result[:success]
  end

  test "search_by_duration searches by duration field" do
    @mock_client.expects(:get)
      .with("recording", {query: "dur:259000"})
      .returns(successful_recording_response)

    result = @search.search_by_duration(259000)

    assert result[:success]
  end

  test "search_by_length searches by length field" do
    @mock_client.expects(:get)
      .with("recording", {query: "length:259000"})
      .returns(successful_recording_response)

    result = @search.search_by_length(259000)

    assert result[:success]
  end

  test "search_by_release_group_mbid searches by release group MBID" do
    rgid = "f4a31f0a-51dd-4fa7-986d-3095c40c5ed9"

    @mock_client.expects(:get)
      .with("recording", {query: "rgid:f4a31f0a\\-51dd\\-4fa7\\-986d\\-3095c40c5ed9"})
      .returns(successful_recording_response)

    result = @search.search_by_release_group_mbid(rgid)

    assert result[:success]
  end

  test "search_by_release searches by release title" do
    @mock_client.expects(:get)
      .with("recording", {query: 'release:Abbey\\ Road'})
      .returns(successful_recording_response)

    result = @search.search_by_release("Abbey Road")

    assert result[:success]
  end

  test "search_by_country searches by country field" do
    @mock_client.expects(:get)
      .with("recording", {query: "country:GB"})
      .returns(successful_recording_response)

    result = @search.search_by_country("GB")

    assert result[:success]
  end

  test "search_by_date searches by date field" do
    @mock_client.expects(:get)
      .with("recording", {query: "date:1969"})
      .returns(successful_recording_response)

    result = @search.search_by_date("1969")

    assert result[:success]
  end

  test "search_by_artist_and_title combines artist and title search" do
    expected_query = 'artist:The\\ Beatles AND title:Come\\ Together'

    @mock_client.expects(:get)
      .with("recording", {query: expected_query})
      .returns(successful_recording_response)

    result = @search.search_by_artist_and_title("The Beatles", "Come Together")

    assert result[:success]
  end

  test "search_by_artist_mbid_and_title combines artist MBID and title search" do
    artist_mbid = "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"
    expected_query = 'arid:b10bbbfc\\-cf9e\\-42e0\\-be17\\-e2c3e1d2600d AND title:Come\\ Together'

    @mock_client.expects(:get)
      .with("recording", {query: expected_query})
      .returns(successful_recording_response)

    result = @search.search_by_artist_mbid_and_title(artist_mbid, "Come Together")

    assert result[:success]
  end

  test "search_artist_recordings searches recordings by artist with filters" do
    artist_mbid = "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"
    filters = {release: "Abbey Road", dur: "259000"}
    expected_query = 'arid:b10bbbfc\\-cf9e\\-42e0\\-be17\\-e2c3e1d2600d AND release:Abbey\\ Road AND dur:259000'

    @mock_client.expects(:get)
      .with("recording", {query: expected_query})
      .returns(successful_recording_response)

    result = @search.search_artist_recordings(artist_mbid, filters)

    assert result[:success]
  end

  test "search_artist_recordings works with no filters" do
    artist_mbid = "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"
    expected_query = 'arid:b10bbbfc\\-cf9e\\-42e0\\-be17\\-e2c3e1d2600d'

    @mock_client.expects(:get)
      .with("recording", {query: expected_query})
      .returns(successful_recording_response)

    result = @search.search_artist_recordings(artist_mbid)

    assert result[:success]
  end

  test "search_by_duration_range searches within duration range" do
    expected_query = "dur:[240000 TO 300000]"

    @mock_client.expects(:get)
      .with("recording", {query: expected_query})
      .returns(successful_recording_response)

    result = @search.search_by_duration_range(240000, 300000)

    assert result[:success]
  end

  test "search performs general search with custom query" do
    @mock_client.expects(:get)
      .with("recording", {query: "title:Come AND artist:Beatles"})
      .returns(successful_recording_response)

    result = @search.search("title:Come AND artist:Beatles")

    assert result[:success]
  end

  test "search includes pagination options" do
    @mock_client.expects(:get)
      .with("recording", {query: "artist:Beatles", limit: 10, offset: 20})
      .returns(successful_recording_response)

    result = @search.search("artist:Beatles", limit: 10, offset: 20)

    assert result[:success]
  end

  test "search_with_criteria builds complex queries" do
    criteria = {
      title: "Come Together",
      arid: "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d",
      isrc: "GBUM71505078"
    }

    expected_query = 'title:Come\\ Together AND arid:b10bbbfc\\-cf9e\\-42e0\\-be17\\-e2c3e1d2600d AND isrc:GBUM71505078'

    @mock_client.expects(:get)
      .with("recording", {query: expected_query})
      .returns(successful_recording_response)

    result = @search.search_with_criteria(criteria)

    assert result[:success]
  end

  test "search_with_criteria skips blank values" do
    criteria = {
      title: "Come Together",
      artist: "",
      isrc: nil
    }

    @mock_client.expects(:get)
      .with("recording", {query: 'title:Come\\ Together'})
      .returns(successful_recording_response)

    result = @search.search_with_criteria(criteria)

    assert result[:success]
  end

  test "search_with_criteria raises error for invalid fields" do
    criteria = {invalid_field: "value"}

    assert_raises(Music::Musicbrainz::Exceptions::QueryError) do
      @search.search_with_criteria(criteria)
    end
  end

  test "search_with_criteria raises error when no criteria provided" do
    criteria = {title: "", artist: nil}

    assert_raises(Music::Musicbrainz::Exceptions::QueryError) do
      @search.search_with_criteria(criteria)
    end
  end

  test "returns raw API response data without processing" do
    @mock_client.expects(:get)
      .with("recording", {query: 'title:Come\\ Together'})
      .returns(successful_recording_response)

    result = @search.search_by_title("Come Together")

    assert result[:success]
    # Should return raw data structure from API
    assert_equal "e3f3c2d4-55c2-4d28-bb47-71f42f2a5ccc", result[:data]["recordings"].first["id"]
    assert_equal "Come Together", result[:data]["recordings"].first["title"]
  end

  test "search handles API errors gracefully" do
    @mock_client.expects(:get)
      .raises(Music::Musicbrainz::Exceptions::NetworkError.new("Connection failed"))

    result = @search.search("title:Come Together")

    refute result[:success]
    assert_includes result[:errors], "Connection failed"
    assert_equal "recording", result[:metadata][:entity_type]
  end

  test "find_by_mbid uses correct MBID field" do
    valid_mbid = "e3f3c2d4-55c2-4d28-bb47-71f42f2a5ccc"

    @mock_client.expects(:get)
      .with("recording", {query: "rid:e3f3c2d4\\-55c2\\-4d28\\-bb47\\-71f42f2a5ccc"})
      .returns(successful_recording_response)

    result = @search.find_by_mbid(valid_mbid)

    assert result[:success]
  end

  test "lookup_by_mbid uses direct lookup with inc parameter" do
    recording_mbid = "e3f3c2d4-55c2-4d28-bb47-71f42f2a5ccc"

    @mock_client.expects(:get)
      .with("recording/#{recording_mbid}", {inc: "artist-credits"})
      .returns(successful_lookup_response)

    result = @search.lookup_by_mbid(recording_mbid)

    assert result[:success]
    assert_equal 1, result[:data]["count"]
    assert_equal "Come Together", result[:data]["recordings"].first["title"]
  end

  test "lookup_by_mbid merges additional options with default inc" do
    recording_mbid = "e3f3c2d4-55c2-4d28-bb47-71f42f2a5ccc"
    options = {limit: 10}

    @mock_client.expects(:get)
      .with("recording/#{recording_mbid}", {inc: "artist-credits", limit: 10})
      .returns(successful_lookup_response)

    result = @search.lookup_by_mbid(recording_mbid, options)

    assert result[:success]
  end

  test "lookup_by_mbid validates MBID format" do
    invalid_mbid = "not-a-valid-mbid"

    assert_raises(Music::Musicbrainz::Exceptions::QueryError) do
      @search.lookup_by_mbid(invalid_mbid)
    end
  end

  test "lookup_by_mbid handles API errors gracefully" do
    recording_mbid = "e3f3c2d4-55c2-4d28-bb47-71f42f2a5ccc"

    @mock_client.expects(:get)
      .raises(Music::Musicbrainz::Exceptions::NetworkError.new("Recording not found"))

    result = @search.lookup_by_mbid(recording_mbid)

    refute result[:success]
    assert_includes result[:errors], "Recording not found"
    assert_equal({recording_mbid: recording_mbid}, result[:metadata][:browse_params])
  end

  test "lookup_by_mbid transforms single recording to array format" do
    recording_mbid = "e3f3c2d4-55c2-4d28-bb47-71f42f2a5ccc"

    @mock_client.expects(:get)
      .with("recording/#{recording_mbid}", {inc: "artist-credits"})
      .returns(successful_lookup_response)

    result = @search.lookup_by_mbid(recording_mbid)

    assert result[:success]
    # Should transform single object to recordings array
    assert result[:data]["recordings"].is_a?(Array)
    assert_equal 1, result[:data]["count"]
    assert_equal 0, result[:data]["offset"]
  end

  private

  def successful_recording_response
    {
      success: true,
      data: {
        "count" => 1,
        "offset" => 0,
        "recordings" => [
          {
            "id" => "e3f3c2d4-55c2-4d28-bb47-71f42f2a5ccc",
            "title" => "Come Together",
            "length" => 259000,
            "artist-credit" => [
              {
                "artist" => {
                  "id" => "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d",
                  "name" => "The Beatles"
                }
              }
            ],
            "isrcs" => ["GBUM71505078"],
            "score" => "100"
          }
        ]
      },
      errors: [],
      metadata: {
        endpoint: "recording",
        response_time: 0.123
      }
    }
  end

  def successful_lookup_response
    {
      success: true,
      data: {
        "id" => "e3f3c2d4-55c2-4d28-bb47-71f42f2a5ccc",
        "title" => "Come Together",
        "length" => 259000,
        "artist-credit" => [
          {
            "name" => "The Beatles",
            "artist" => {
              "id" => "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d",
              "name" => "The Beatles",
              "sort-name" => "Beatles, The"
            }
          }
        ],
        "isrcs" => ["GBUM71505078"],
        "first-release-date" => "1969-09-26"
      },
      errors: [],
      metadata: {
        endpoint: "recording/e3f3c2d4-55c2-4d28-bb47-71f42f2a5ccc",
        response_time: 0.145
      }
    }
  end
end
