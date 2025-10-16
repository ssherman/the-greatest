# frozen_string_literal: true

require "test_helper"

class Music::Musicbrainz::Search::WorkSearchTest < ActiveSupport::TestCase
  def setup
    @mock_client = mock("client")
    @search = Music::Musicbrainz::Search::WorkSearch.new(@mock_client)
  end

  test "entity_type returns work" do
    assert_equal "work", @search.entity_type
  end

  test "mbid_field returns wid" do
    assert_equal "wid", @search.mbid_field
  end

  test "available_fields returns correct work fields" do
    expected_fields = %w[
      work workaccent wid alias arid artist tag type
      comment iswc lang recording recording_count rid
    ]
    assert_equal expected_fields, @search.available_fields
  end

  test "search_by_title searches by work field" do
    @mock_client.expects(:get)
      .with("work", {query: "work:Yesterday"})
      .returns(successful_work_response)

    result = @search.search_by_title("Yesterday")

    assert result[:success]
    assert_equal 1, result[:data]["count"]
  end

  test "search_by_title_with_accent searches by workaccent field" do
    @mock_client.expects(:get)
      .with("work", {query: 'workaccent:Für\\ Elise'})
      .returns(successful_work_response)

    result = @search.search_by_title_with_accent("Für Elise")

    assert result[:success]
  end

  test "search_by_artist_mbid searches by artist MBID" do
    artist_mbid = "ba550d0e-adac-4208-b99b-7a5f8d7bcf31"

    @mock_client.expects(:get)
      .with("work", {query: "arid:ba550d0e\\-adac\\-4208\\-b99b\\-7a5f8d7bcf31"})
      .returns(successful_work_response)

    result = @search.search_by_artist_mbid(artist_mbid)

    assert result[:success]
  end

  test "search_by_artist_name searches by artist name" do
    @mock_client.expects(:get)
      .with("work", {query: 'artist:Paul\\ McCartney'})
      .returns(successful_work_response)

    result = @search.search_by_artist_name("Paul McCartney")

    assert result[:success]
  end

  test "search_by_alias searches by alias field" do
    @mock_client.expects(:get)
      .with("work", {query: 'alias:Scrambled\\ Eggs'})
      .returns(successful_work_response)

    result = @search.search_by_alias("Scrambled Eggs")

    assert result[:success]
  end

  test "search_by_iswc searches by ISWC field" do
    @mock_client.expects(:get)
      .with("work", {query: 'iswc:T\\-010.140.236\\-1'})
      .returns(successful_work_response)

    result = @search.search_by_iswc("T-010.140.236-1")

    assert result[:success]
  end

  test "search_by_tag searches by tag field" do
    @mock_client.expects(:get)
      .with("work", {query: "tag:pop"})
      .returns(successful_work_response)

    result = @search.search_by_tag("pop")

    assert result[:success]
  end

  test "search_by_type searches by type field" do
    @mock_client.expects(:get)
      .with("work", {query: "type:song"})
      .returns(successful_work_response)

    result = @search.search_by_type("song")

    assert result[:success]
  end

  test "search_by_language searches by language code" do
    @mock_client.expects(:get)
      .with("work", {query: "lang:eng"})
      .returns(successful_work_response)

    result = @search.search_by_language("eng")

    assert result[:success]
  end

  test "search_by_recording_title searches by recording field" do
    @mock_client.expects(:get)
      .with("work", {query: "recording:Yesterday"})
      .returns(successful_work_response)

    result = @search.search_by_recording_title("Yesterday")

    assert result[:success]
  end

  test "search_by_recording_mbid searches by recording MBID" do
    recording_mbid = "f970f1e0-0f9b-4e59-8b12-b5cde6037f4c"

    @mock_client.expects(:get)
      .with("work", {query: "rid:f970f1e0\\-0f9b\\-4e59\\-8b12\\-b5cde6037f4c"})
      .returns(successful_work_response)

    result = @search.search_by_recording_mbid(recording_mbid)

    assert result[:success]
  end

  test "search_by_recording_count searches by recording count" do
    @mock_client.expects(:get)
      .with("work", {query: "recording_count:50"})
      .returns(successful_work_response)

    result = @search.search_by_recording_count(50)

    assert result[:success]
  end

  test "search_by_comment searches by comment field" do
    @mock_client.expects(:get)
      .with("work", {query: 'comment:Beatles\\ song'})
      .returns(successful_work_response)

    result = @search.search_by_comment("Beatles song")

    assert result[:success]
  end

  test "search_by_artist_and_title combines artist and title search" do
    expected_query = 'artist:Paul\\ McCartney AND work:Yesterday'

    @mock_client.expects(:get)
      .with("work", {query: expected_query})
      .returns(successful_work_response)

    result = @search.search_by_artist_and_title("Paul McCartney", "Yesterday")

    assert result[:success]
  end

  test "search_by_artist_mbid_and_title combines artist MBID and title search" do
    artist_mbid = "ba550d0e-adac-4208-b99b-7a5f8d7bcf31"
    expected_query = 'arid:ba550d0e\\-adac\\-4208\\-b99b\\-7a5f8d7bcf31 AND work:Yesterday'

    @mock_client.expects(:get)
      .with("work", {query: expected_query})
      .returns(successful_work_response)

    result = @search.search_by_artist_mbid_and_title(artist_mbid, "Yesterday")

    assert result[:success]
  end

  test "search_artist_works searches works by artist with filters" do
    artist_mbid = "ba550d0e-adac-4208-b99b-7a5f8d7bcf31"
    filters = {type: "song", lang: "eng"}
    expected_query = 'arid:ba550d0e\\-adac\\-4208\\-b99b\\-7a5f8d7bcf31 AND type:song AND lang:eng'

    @mock_client.expects(:get)
      .with("work", {query: expected_query})
      .returns(successful_work_response)

    result = @search.search_artist_works(artist_mbid, filters)

    assert result[:success]
  end

  test "search_artist_works works with no filters" do
    artist_mbid = "ba550d0e-adac-4208-b99b-7a5f8d7bcf31"
    expected_query = 'arid:ba550d0e\\-adac\\-4208\\-b99b\\-7a5f8d7bcf31'

    @mock_client.expects(:get)
      .with("work", {query: expected_query})
      .returns(successful_work_response)

    result = @search.search_artist_works(artist_mbid)

    assert result[:success]
  end

  test "search_by_recording_count_range searches within recording count range" do
    expected_query = "recording_count:[10 TO 100]"

    @mock_client.expects(:get)
      .with("work", {query: expected_query})
      .returns(successful_work_response)

    result = @search.search_by_recording_count_range(10, 100)

    assert result[:success]
  end

  test "search performs general search with custom query" do
    @mock_client.expects(:get)
      .with("work", {query: "work:Yesterday AND artist:McCartney"})
      .returns(successful_work_response)

    result = @search.search("work:Yesterday AND artist:McCartney")

    assert result[:success]
  end

  test "search includes pagination options" do
    @mock_client.expects(:get)
      .with("work", {query: "artist:McCartney", limit: 10, offset: 20})
      .returns(successful_work_response)

    result = @search.search("artist:McCartney", limit: 10, offset: 20)

    assert result[:success]
  end

  test "search_with_criteria builds complex queries" do
    criteria = {
      work: "Yesterday",
      arid: "ba550d0e-adac-4208-b99b-7a5f8d7bcf31",
      iswc: "T-010.140.236-1"
    }

    expected_query = 'work:Yesterday AND arid:ba550d0e\\-adac\\-4208\\-b99b\\-7a5f8d7bcf31 AND iswc:T\\-010.140.236\\-1'

    @mock_client.expects(:get)
      .with("work", {query: expected_query})
      .returns(successful_work_response)

    result = @search.search_with_criteria(criteria)

    assert result[:success]
  end

  test "search_with_criteria skips blank values" do
    criteria = {
      work: "Yesterday",
      artist: "",
      iswc: nil
    }

    @mock_client.expects(:get)
      .with("work", {query: "work:Yesterday"})
      .returns(successful_work_response)

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
    criteria = {work: "", artist: nil}

    assert_raises(Music::Musicbrainz::Exceptions::QueryError) do
      @search.search_with_criteria(criteria)
    end
  end

  test "returns raw API response data without processing" do
    @mock_client.expects(:get)
      .with("work", {query: "work:Yesterday"})
      .returns(successful_work_response)

    result = @search.search_by_title("Yesterday")

    assert result[:success]
    # Should return raw data structure from API
    assert_equal "10c1a66a-8166-32ec-a00f-540f111ce7a3", result[:data]["works"].first["id"]
    assert_equal "Yesterday", result[:data]["works"].first["title"]
  end

  test "search handles API errors gracefully" do
    @mock_client.expects(:get)
      .raises(Music::Musicbrainz::Exceptions::NetworkError.new("Connection failed"))

    result = @search.search("work:Yesterday")

    refute result[:success]
    assert_includes result[:errors], "Connection failed"
    assert_equal "work", result[:metadata][:entity_type]
  end

  test "find_by_mbid uses correct MBID field" do
    valid_mbid = "10c1a66a-8166-32ec-a00f-540f111ce7a3"

    @mock_client.expects(:get)
      .with("work", {query: "wid:10c1a66a\\-8166\\-32ec\\-a00f\\-540f111ce7a3"})
      .returns(successful_work_response)

    result = @search.find_by_mbid(valid_mbid)

    assert result[:success]
  end

  private

  def successful_work_response
    {
      success: true,
      data: {
        "count" => 1,
        "offset" => 0,
        "works" => [
          {
            "id" => "10c1a66a-8166-32ec-a00f-540f111ce7a3",
            "title" => "Yesterday",
            "type" => "Song",
            "iswcs" => ["T-010.140.236-1"],
            "language" => "eng",
            "relations" => [
              {
                "type" => "composer",
                "direction" => "backward",
                "artist" => {
                  "id" => "ba550d0e-adac-4208-b99b-7a5f8d7bcf31",
                  "name" => "Paul McCartney",
                  "sort-name" => "McCartney, Paul"
                }
              }
            ],
            "score" => "100"
          }
        ]
      },
      errors: [],
      metadata: {
        endpoint: "work",
        response_time: 0.123
      }
    }
  end
end
