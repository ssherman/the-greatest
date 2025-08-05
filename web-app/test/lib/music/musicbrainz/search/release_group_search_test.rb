# frozen_string_literal: true

require "test_helper"

class Music::Musicbrainz::Search::ReleaseGroupSearchTest < ActiveSupport::TestCase
  def setup
    @mock_client = mock("client")
    @search = Music::Musicbrainz::Search::ReleaseGroupSearch.new(@mock_client)
  end

  test "entity_type returns release-group" do
    assert_equal "release-group", @search.entity_type
  end

  test "mbid_field returns rgid" do
    assert_equal "rgid", @search.mbid_field
  end

  test "available_fields returns correct release group fields" do
    expected_fields = %w[
      alias arid artist artistname comment creditname
      firstreleasedate primarytype reid release releasegroup
      releasegroupaccent releases rgid secondarytype status
      tag type title country date
    ]
    assert_equal expected_fields, @search.available_fields
  end

  test "search_by_title searches by title field" do
    @mock_client.expects(:get)
      .with("release-group", {query: 'title:Abbey\\ Road'})
      .returns(successful_release_group_response)

    result = @search.search_by_title("Abbey Road")

    assert result[:success]
    assert_equal 1, result[:data]["count"]
  end

  test "search_by_artist_mbid searches by artist MBID" do
    artist_mbid = "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"

    @mock_client.expects(:get)
      .with("release-group", {query: "arid:b10bbbfc\\-cf9e\\-42e0\\-be17\\-e2c3e1d2600d"})
      .returns(successful_release_group_response)

    result = @search.search_by_artist_mbid(artist_mbid)

    assert result[:success]
  end

  test "search_by_artist_name searches by artist name" do
    @mock_client.expects(:get)
      .with("release-group", {query: 'artist:The\\ Beatles'})
      .returns(successful_release_group_response)

    result = @search.search_by_artist_name("The Beatles")

    assert result[:success]
  end

  test "search_by_tag searches by tag field" do
    @mock_client.expects(:get)
      .with("release-group", {query: "tag:rock"})
      .returns(successful_release_group_response)

    result = @search.search_by_tag("rock")

    assert result[:success]
  end

  test "search_by_type searches by type field" do
    @mock_client.expects(:get)
      .with("release-group", {query: "type:album"})
      .returns(successful_release_group_response)

    result = @search.search_by_type("album")

    assert result[:success]
  end

  test "search_by_country searches by country field" do
    @mock_client.expects(:get)
      .with("release-group", {query: "country:GB"})
      .returns(successful_release_group_response)

    result = @search.search_by_country("GB")

    assert result[:success]
  end

  test "search_by_date searches by date field" do
    @mock_client.expects(:get)
      .with("release-group", {query: "date:1969"})
      .returns(successful_release_group_response)

    result = @search.search_by_date("1969")

    assert result[:success]
  end

  test "search_by_first_release_date searches by first release date" do
    @mock_client.expects(:get)
      .with("release-group", {query: 'firstreleasedate:1969\\-09\\-26'})
      .returns(successful_release_group_response)

    result = @search.search_by_first_release_date("1969-09-26")

    assert result[:success]
  end

  test "search_by_artist_and_title combines artist and title search" do
    expected_query = 'artist:The\\ Beatles AND title:Abbey\\ Road'

    @mock_client.expects(:get)
      .with("release-group", {query: expected_query})
      .returns(successful_release_group_response)

    result = @search.search_by_artist_and_title("The Beatles", "Abbey Road")

    assert result[:success]
  end

  test "search_by_artist_mbid_and_title combines artist MBID and title search" do
    artist_mbid = "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"
    expected_query = 'arid:b10bbbfc\\-cf9e\\-42e0\\-be17\\-e2c3e1d2600d AND title:Abbey\\ Road'

    @mock_client.expects(:get)
      .with("release-group", {query: expected_query})
      .returns(successful_release_group_response)

    result = @search.search_by_artist_mbid_and_title(artist_mbid, "Abbey Road")

    assert result[:success]
  end

  test "search_artist_albums searches albums by artist with filters" do
    artist_mbid = "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"
    filters = {type: "album", country: "GB"}
    expected_query = 'arid:b10bbbfc\\-cf9e\\-42e0\\-be17\\-e2c3e1d2600d AND type:album AND country:GB'

    @mock_client.expects(:get)
      .with("release-group", {query: expected_query})
      .returns(successful_release_group_response)

    result = @search.search_artist_albums(artist_mbid, filters)

    assert result[:success]
  end

  test "search_artist_albums works with no filters" do
    artist_mbid = "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"
    expected_query = 'arid:b10bbbfc\\-cf9e\\-42e0\\-be17\\-e2c3e1d2600d'

    @mock_client.expects(:get)
      .with("release-group", {query: expected_query})
      .returns(successful_release_group_response)

    result = @search.search_artist_albums(artist_mbid)

    assert result[:success]
  end

  test "search performs general search with custom query" do
    @mock_client.expects(:get)
      .with("release-group", {query: "title:Abbey AND artist:Beatles"})
      .returns(successful_release_group_response)

    result = @search.search("title:Abbey AND artist:Beatles")

    assert result[:success]
  end

  test "search includes pagination options" do
    @mock_client.expects(:get)
      .with("release-group", {query: "artist:Beatles", limit: 10, offset: 20})
      .returns(successful_release_group_response)

    result = @search.search("artist:Beatles", limit: 10, offset: 20)

    assert result[:success]
  end

  test "search_with_criteria builds complex queries" do
    criteria = {
      title: "Abbey Road",
      arid: "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d",
      type: "album"
    }

    expected_query = 'title:Abbey\\ Road AND arid:b10bbbfc\\-cf9e\\-42e0\\-be17\\-e2c3e1d2600d AND type:album'

    @mock_client.expects(:get)
      .with("release-group", {query: expected_query})
      .returns(successful_release_group_response)

    result = @search.search_with_criteria(criteria)

    assert result[:success]
  end

  test "search_with_criteria skips blank values" do
    criteria = {
      title: "Abbey Road",
      artist: "",
      type: nil
    }

    @mock_client.expects(:get)
      .with("release-group", {query: 'title:Abbey\\ Road'})
      .returns(successful_release_group_response)

    result = @search.search_with_criteria(criteria)

    assert result[:success]
  end

  test "search_with_criteria raises error for invalid fields" do
    criteria = {invalid_field: "value"}

    assert_raises(Music::Musicbrainz::QueryError) do
      @search.search_with_criteria(criteria)
    end
  end

  test "search_with_criteria raises error when no criteria provided" do
    criteria = {title: "", artist: nil}

    assert_raises(Music::Musicbrainz::QueryError) do
      @search.search_with_criteria(criteria)
    end
  end

  test "search_with_criteria works with new fields" do
    criteria = {
      primarytype: "Album",
      secondarytype: "Compilation",
      alias: "White Album",
      releases: "1"
    }

    expected_query = 'primarytype:Album AND secondarytype:Compilation AND alias:White\\ Album AND releases:1'

    @mock_client.expects(:get)
      .with("release-group", {query: expected_query})
      .returns(successful_release_group_response)

    result = @search.search_with_criteria(criteria)

    assert result[:success]
  end

  test "returns raw API response data without processing" do
    @mock_client.expects(:get)
      .with("release-group", {query: 'title:Abbey\\ Road'})
      .returns(successful_release_group_response)

    result = @search.search_by_title("Abbey Road")

    assert result[:success]
    # Should return raw data structure from API
    assert_equal "f4a31f0a-51dd-4fa7-986d-3095c40c5ed9", result[:data]["release-groups"].first["id"]
    assert_equal "Abbey Road", result[:data]["release-groups"].first["title"]
  end

  test "search handles API errors gracefully" do
    @mock_client.expects(:get)
      .raises(Music::Musicbrainz::NetworkError.new("Connection failed"))

    result = @search.search("title:Abbey Road")

    refute result[:success]
    assert_includes result[:errors], "Connection failed"
    assert_equal "release-group", result[:metadata][:entity_type]
  end

  test "find_by_mbid uses correct MBID field" do
    valid_mbid = "f4a31f0a-51dd-4fa7-986d-3095c40c5ed9"

    @mock_client.expects(:get)
      .with("release-group", {query: "rgid:f4a31f0a\\-51dd\\-4fa7\\-986d\\-3095c40c5ed9"})
      .returns(successful_release_group_response)

    result = @search.find_by_mbid(valid_mbid)

    assert result[:success]
  end

  test "search_by_primary_type searches by primary type field" do
    @mock_client.expects(:get)
      .with("release-group", {query: "primarytype:Album"})
      .returns(successful_release_group_response)

    result = @search.search_by_primary_type("Album")

    assert result[:success]
  end

  test "search_by_secondary_type searches by secondary type field" do
    @mock_client.expects(:get)
      .with("release-group", {query: "secondarytype:Compilation"})
      .returns(successful_release_group_response)

    result = @search.search_by_secondary_type("Compilation")

    assert result[:success]
  end

  test "search_by_alias searches by alias field" do
    @mock_client.expects(:get)
      .with("release-group", {query: 'alias:White\\ Album'})
      .returns(successful_release_group_response)

    result = @search.search_by_alias("White Album")

    assert result[:success]
  end

  test "search_by_credit_name searches by credit name field" do
    @mock_client.expects(:get)
      .with("release-group", {query: 'creditname:The\\ Beatles'})
      .returns(successful_release_group_response)

    result = @search.search_by_credit_name("The Beatles")

    assert result[:success]
  end

  test "search_by_release_mbid searches by release MBID" do
    release_mbid = "f4a31f0a-51dd-4fa7-986d-3095c40c5ed9"

    @mock_client.expects(:get)
      .with("release-group", {query: "reid:f4a31f0a\\-51dd\\-4fa7\\-986d\\-3095c40c5ed9"})
      .returns(successful_release_group_response)

    result = @search.search_by_release_mbid(release_mbid)

    assert result[:success]
  end

  test "search_by_release_title searches by release title field" do
    @mock_client.expects(:get)
      .with("release-group", {query: 'release:Abbey\\ Road'})
      .returns(successful_release_group_response)

    result = @search.search_by_release_title("Abbey Road")

    assert result[:success]
  end

  test "search_by_release_count searches by number of releases" do
    @mock_client.expects(:get)
      .with("release-group", {query: "releases:1"})
      .returns(successful_release_group_response)

    result = @search.search_by_release_count(1)

    assert result[:success]
  end

  test "search_primary_albums_only searches for official primary albums without artist" do
    expected_query = "primarytype:Album AND -secondarytype:* AND status:Official"

    @mock_client.expects(:get)
      .with("release-group", {query: expected_query})
      .returns(successful_release_group_response)

    result = @search.search_primary_albums_only

    assert result[:success]
  end

  test "search_primary_albums_only searches for official primary albums with artist" do
    artist_mbid = "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"
    expected_query = "primarytype:Album AND -secondarytype:* AND status:Official AND arid:b10bbbfc\\-cf9e\\-42e0\\-be17\\-e2c3e1d2600d"

    @mock_client.expects(:get)
      .with("release-group", {query: expected_query})
      .returns(successful_release_group_response)

    result = @search.search_primary_albums_only(artist_mbid)

    assert result[:success]
  end

  private

  def successful_release_group_response
    {
      success: true,
      data: {
        "count" => 1,
        "offset" => 0,
        "release-groups" => [
          {
            "id" => "f4a31f0a-51dd-4fa7-986d-3095c40c5ed9",
            "title" => "Abbey Road",
            "primary-type" => "Album",
            "artist-credit" => [
              {
                "artist" => {
                  "id" => "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d",
                  "name" => "The Beatles"
                }
              }
            ],
            "first-release-date" => "1969-09-26",
            "score" => "100"
          }
        ]
      },
      errors: [],
      metadata: {
        endpoint: "release-group",
        response_time: 0.123
      }
    }
  end
end
