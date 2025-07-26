# frozen_string_literal: true

require "test_helper"

class Music::Musicbrainz::Search::ReleaseSearchTest < ActiveSupport::TestCase
  def setup
    @mock_client = mock("client")
    @search = Music::Musicbrainz::Search::ReleaseSearch.new(@mock_client)
  end

  test "entity_type returns release" do
    assert_equal "release", @search.entity_type
  end

  test "mbid_field returns reid" do
    assert_equal "reid", @search.mbid_field
  end

  test "available_fields returns correct release fields" do
    expected_fields = %w[
      release reid alias arid artist asin barcode catno comment
      country creditname date discids format laid label language
      mediums packaging primarytype puid quality rgid releasegroup
      script secondarytype status tag tracks
    ]
    assert_equal expected_fields, @search.available_fields
  end

  test "search_by_title searches by release field" do
    @mock_client.expects(:get)
      .with("release", {query: 'release:Abbey\\ Road'})
      .returns(successful_release_response)

    result = @search.search_by_title("Abbey Road")

    assert result[:success]
    assert_equal 1, result[:data]["count"]
  end

  test "search_by_artist_mbid searches by artist MBID" do
    artist_mbid = "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"

    @mock_client.expects(:get)
      .with("release", {query: "arid:b10bbbfc\\-cf9e\\-42e0\\-be17\\-e2c3e1d2600d"})
      .returns(successful_release_response)

    result = @search.search_by_artist_mbid(artist_mbid)

    assert result[:success]
  end

  test "search_by_artist_name searches by artist name" do
    @mock_client.expects(:get)
      .with("release", {query: 'artist:The\\ Beatles'})
      .returns(successful_release_response)

    result = @search.search_by_artist_name("The Beatles")

    assert result[:success]
  end

  test "search_by_release_group_mbid searches by release group MBID" do
    rg_mbid = "b84ee12a-9f6e-3f70-afb2-5a9c40e74f4d"

    @mock_client.expects(:get)
      .with("release", {query: "rgid:b84ee12a\\-9f6e\\-3f70\\-afb2\\-5a9c40e74f4d"})
      .returns(successful_release_response)

    result = @search.search_by_release_group_mbid(rg_mbid)

    assert result[:success]
  end

  test "search_by_release_group_name searches by release group name" do
    @mock_client.expects(:get)
      .with("release", {query: 'releasegroup:Abbey\\ Road'})
      .returns(successful_release_response)

    result = @search.search_by_release_group_name("Abbey Road")

    assert result[:success]
  end

  test "search_by_barcode searches by barcode field" do
    @mock_client.expects(:get)
      .with("release", {query: "barcode:077774644020"})
      .returns(successful_release_response)

    result = @search.search_by_barcode("077774644020")

    assert result[:success]
  end

  test "search_by_catalog_number searches by catalog number" do
    @mock_client.expects(:get)
      .with("release", {query: 'catno:PCS\\ 7088'})
      .returns(successful_release_response)

    result = @search.search_by_catalog_number("PCS 7088")

    assert result[:success]
  end

  test "search_by_asin searches by Amazon ASIN" do
    @mock_client.expects(:get)
      .with("release", {query: "asin:B000002UAL"})
      .returns(successful_release_response)

    result = @search.search_by_asin("B000002UAL")

    assert result[:success]
  end

  test "search_by_country searches by country code" do
    @mock_client.expects(:get)
      .with("release", {query: "country:GB"})
      .returns(successful_release_response)

    result = @search.search_by_country("GB")

    assert result[:success]
  end

  test "search_by_format searches by format" do
    @mock_client.expects(:get)
      .with("release", {query: "format:CD"})
      .returns(successful_release_response)

    result = @search.search_by_format("CD")

    assert result[:success]
  end

  test "search_by_label_mbid searches by label MBID" do
    label_mbid = "8f638e84-0b79-4f35-a80c-7b9c73b3d0a1"

    @mock_client.expects(:get)
      .with("release", {query: "laid:8f638e84\\-0b79\\-4f35\\-a80c\\-7b9c73b3d0a1"})
      .returns(successful_release_response)

    result = @search.search_by_label_mbid(label_mbid)

    assert result[:success]
  end

  test "search_by_label_name searches by label name" do
    @mock_client.expects(:get)
      .with("release", {query: "label:Parlophone"})
      .returns(successful_release_response)

    result = @search.search_by_label_name("Parlophone")

    assert result[:success]
  end

  test "search_by_status searches by release status" do
    @mock_client.expects(:get)
      .with("release", {query: "status:Official"})
      .returns(successful_release_response)

    result = @search.search_by_status("Official")

    assert result[:success]
  end

  test "search_by_packaging searches by packaging type" do
    @mock_client.expects(:get)
      .with("release", {query: 'packaging:Jewel\\ Case'})
      .returns(successful_release_response)

    result = @search.search_by_packaging("Jewel Case")

    assert result[:success]
  end

  test "search_by_primary_type searches by primary type" do
    @mock_client.expects(:get)
      .with("release", {query: "primarytype:Album"})
      .returns(successful_release_response)

    result = @search.search_by_primary_type("Album")

    assert result[:success]
  end

  test "search_by_secondary_type searches by secondary type" do
    @mock_client.expects(:get)
      .with("release", {query: "secondarytype:Compilation"})
      .returns(successful_release_response)

    result = @search.search_by_secondary_type("Compilation")

    assert result[:success]
  end

  test "search_by_language searches by language code" do
    @mock_client.expects(:get)
      .with("release", {query: "language:eng"})
      .returns(successful_release_response)

    result = @search.search_by_language("eng")

    assert result[:success]
  end

  test "search_by_script searches by script" do
    @mock_client.expects(:get)
      .with("release", {query: "script:Latin"})
      .returns(successful_release_response)

    result = @search.search_by_script("Latin")

    assert result[:success]
  end

  test "search_by_date searches by release date" do
    @mock_client.expects(:get)
      .with("release", {query: 'date:1969\\-09\\-26'})
      .returns(successful_release_response)

    result = @search.search_by_date("1969-09-26")

    assert result[:success]
  end

  test "search_by_medium_count searches by number of mediums" do
    @mock_client.expects(:get)
      .with("release", {query: "mediums:1"})
      .returns(successful_release_response)

    result = @search.search_by_medium_count(1)

    assert result[:success]
  end

  test "search_by_track_count searches by number of tracks" do
    @mock_client.expects(:get)
      .with("release", {query: "tracks:17"})
      .returns(successful_release_response)

    result = @search.search_by_track_count(17)

    assert result[:success]
  end

  test "search_by_tag searches by tag" do
    @mock_client.expects(:get)
      .with("release", {query: "tag:rock"})
      .returns(successful_release_response)

    result = @search.search_by_tag("rock")

    assert result[:success]
  end

  test "search_by_alias searches by alias" do
    @mock_client.expects(:get)
      .with("release", {query: 'alias:Abbey\\ Rd'})
      .returns(successful_release_response)

    result = @search.search_by_alias("Abbey Rd")

    assert result[:success]
  end

  test "search_by_comment searches by disambiguation comment" do
    @mock_client.expects(:get)
      .with("release", {query: "comment:remastered"})
      .returns(successful_release_response)

    result = @search.search_by_comment("remastered")

    assert result[:success]
  end

  test "search_by_credit_name searches by credit name" do
    @mock_client.expects(:get)
      .with("release", {query: "creditname:Beatles"})
      .returns(successful_release_response)

    result = @search.search_by_credit_name("Beatles")

    assert result[:success]
  end

  test "search_by_quality searches by data quality" do
    @mock_client.expects(:get)
      .with("release", {query: "quality:high"})
      .returns(successful_release_response)

    result = @search.search_by_quality("high")

    assert result[:success]
  end

  test "search_by_disc_ids searches by disc IDs" do
    @mock_client.expects(:get)
      .with("release", {query: 'discids:Wn8eRBtfLDfM0qjYPdxrz.Zjs_U\\-'})
      .returns(successful_release_response)

    result = @search.search_by_disc_ids("Wn8eRBtfLDfM0qjYPdxrz.Zjs_U-")

    assert result[:success]
  end

  test "search_by_puid searches by PUID" do
    @mock_client.expects(:get)
      .with("release", {query: 'puid:4e0d7c8b\\-7d7e\\-4f4a\\-8e5b\\-1e4c4b5a3a2a'})
      .returns(successful_release_response)

    result = @search.search_by_puid("4e0d7c8b-7d7e-4f4a-8e5b-1e4c4b5a3a2a")

    assert result[:success]
  end

  test "search_by_artist_and_title combines artist and title search" do
    expected_query = 'artist:The\\ Beatles AND release:Abbey\\ Road'

    @mock_client.expects(:get)
      .with("release", {query: expected_query})
      .returns(successful_release_response)

    result = @search.search_by_artist_and_title("The Beatles", "Abbey Road")

    assert result[:success]
  end

  test "search_by_artist_mbid_and_title combines artist MBID and title search" do
    artist_mbid = "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"
    expected_query = 'arid:b10bbbfc\\-cf9e\\-42e0\\-be17\\-e2c3e1d2600d AND release:Abbey\\ Road'

    @mock_client.expects(:get)
      .with("release", {query: expected_query})
      .returns(successful_release_response)

    result = @search.search_by_artist_mbid_and_title(artist_mbid, "Abbey Road")

    assert result[:success]
  end

  test "search_artist_releases searches releases by artist with filters" do
    artist_mbid = "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"
    filters = {format: "CD", country: "GB", status: "Official"}
    expected_query = 'arid:b10bbbfc\\-cf9e\\-42e0\\-be17\\-e2c3e1d2600d AND format:CD AND country:GB AND status:Official'

    @mock_client.expects(:get)
      .with("release", {query: expected_query})
      .returns(successful_release_response)

    result = @search.search_artist_releases(artist_mbid, filters)

    assert result[:success]
  end

  test "search_artist_releases works with no filters" do
    artist_mbid = "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"
    expected_query = 'arid:b10bbbfc\\-cf9e\\-42e0\\-be17\\-e2c3e1d2600d'

    @mock_client.expects(:get)
      .with("release", {query: expected_query})
      .returns(successful_release_response)

    result = @search.search_artist_releases(artist_mbid)

    assert result[:success]
  end

  test "search_by_date_range searches within date range" do
    expected_query = "date:[1969 TO 1970]"

    @mock_client.expects(:get)
      .with("release", {query: expected_query})
      .returns(successful_release_response)

    result = @search.search_by_date_range("1969", "1970")

    assert result[:success]
  end

  test "search_by_track_count_range searches within track count range" do
    expected_query = "tracks:[10 TO 20]"

    @mock_client.expects(:get)
      .with("release", {query: expected_query})
      .returns(successful_release_response)

    result = @search.search_by_track_count_range(10, 20)

    assert result[:success]
  end

  test "search performs general search with custom query" do
    @mock_client.expects(:get)
      .with("release", {query: 'release:Abbey\\ Road AND format:CD'})
      .returns(successful_release_response)

    result = @search.search("release:Abbey\\ Road AND format:CD")

    assert result[:success]
  end

  test "search includes pagination options" do
    @mock_client.expects(:get)
      .with("release", {query: "artist:Beatles", limit: 10, offset: 20})
      .returns(successful_release_response)

    result = @search.search("artist:Beatles", limit: 10, offset: 20)

    assert result[:success]
  end

  test "search_with_criteria builds complex queries" do
    criteria = {
      release: "Abbey Road",
      arid: "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d",
      format: "CD",
      country: "GB"
    }

    expected_query = 'release:Abbey\\ Road AND arid:b10bbbfc\\-cf9e\\-42e0\\-be17\\-e2c3e1d2600d AND format:CD AND country:GB'

    @mock_client.expects(:get)
      .with("release", {query: expected_query})
      .returns(successful_release_response)

    result = @search.search_with_criteria(criteria)

    assert result[:success]
  end

  test "search_with_criteria skips blank values" do
    criteria = {
      release: "Abbey Road",
      artist: "",
      format: nil
    }

    @mock_client.expects(:get)
      .with("release", {query: 'release:Abbey\\ Road'})
      .returns(successful_release_response)

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
    criteria = {release: "", artist: nil}

    assert_raises(Music::Musicbrainz::QueryError) do
      @search.search_with_criteria(criteria)
    end
  end

  test "returns raw API response data without processing" do
    @mock_client.expects(:get)
      .with("release", {query: 'release:Abbey\\ Road'})
      .returns(successful_release_response)

    result = @search.search_by_title("Abbey Road")

    assert result[:success]
    # Should return raw data structure from API
    assert_equal "b84ee12a-9f6e-3f70-afb2-5a9c40e74f4d", result[:data]["releases"].first["id"]
    assert_equal "Abbey Road", result[:data]["releases"].first["title"]
  end

  test "search handles API errors gracefully" do
    @mock_client.expects(:get)
      .raises(Music::Musicbrainz::NetworkError.new("Connection failed"))

    result = @search.search("release:Abbey\\ Road")

    refute result[:success]
    assert_includes result[:errors], "Connection failed"
    assert_equal "release", result[:metadata][:entity_type]
  end

  test "find_by_mbid uses correct MBID field" do
    valid_mbid = "b84ee12a-9f6e-3f70-afb2-5a9c40e74f4d"

    @mock_client.expects(:get)
      .with("release", {query: "reid:b84ee12a\\-9f6e\\-3f70\\-afb2\\-5a9c40e74f4d"})
      .returns(successful_release_response)

    result = @search.find_by_mbid(valid_mbid)

    assert result[:success]
  end

  private

  def successful_release_response
    {
      success: true,
      data: {
        "count" => 1,
        "offset" => 0,
        "releases" => [
          {
            "id" => "b84ee12a-9f6e-3f70-afb2-5a9c40e74f4d",
            "title" => "Abbey Road",
            "status" => "Official",
            "packaging" => "Jewel Case",
            "text-representation" => {
              "language" => "eng",
              "script" => "Latn"
            },
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
            "release-group" => {
              "id" => "b84ee12a-9f6e-3f70-afb2-5a9c40e74f4d",
              "type" => "Album",
              "primary-type" => "Album"
            },
            "date" => "1969-09-26",
            "country" => "GB",
            "barcode" => "077774644020",
            "asin" => "B000002UAL",
            "label-info" => [
              {
                "catalog-number" => "PCS 7088",
                "label" => {
                  "id" => "8f638e84-0b79-4f35-a80c-7b9c73b3d0a1",
                  "name" => "Parlophone"
                }
              }
            ],
            "medium-list" => [
              {
                "position" => 1,
                "format" => "CD",
                "disc-list" => [
                  {
                    "id" => "Wn8eRBtfLDfM0qjYPdxrz.Zjs_U-"
                  }
                ],
                "track-count" => 17
              }
            ],
            "score" => "100"
          }
        ]
      },
      errors: [],
      metadata: {
        endpoint: "release",
        response_time: 0.156
      }
    }
  end
end
