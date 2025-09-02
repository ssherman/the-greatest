# frozen_string_literal: true

require "test_helper"

class Music::Musicbrainz::Search::SeriesSearchTest < ActiveSupport::TestCase
  def setup
    @mock_client = mock("client")
    @search = Music::Musicbrainz::Search::SeriesSearch.new(@mock_client)
  end

  test "entity_type returns series" do
    assert_equal "series", @search.entity_type
  end

  test "mbid_field returns sid" do
    assert_equal "sid", @search.mbid_field
  end

  test "available_fields returns correct series fields" do
    expected_fields = %w[
      series seriesaccent alias comment sid tag type
    ]
    assert_equal expected_fields, @search.available_fields
  end

  test "search_by_name searches by series field" do
    @mock_client.expects(:get)
      .with("series", {query: 'series:Vice\'s\\ 100\\ Best\\ Albums'})
      .returns(successful_series_response)

    result = @search.search_by_name("Vice's 100 Best Albums")

    assert result[:success]
    assert_equal 1, result[:data]["count"]
  end

  test "search_by_name_with_diacritics searches by seriesaccent field" do
    @mock_client.expects(:get)
      .with("series", {query: 'seriesaccent:Naïve\\ Series'})
      .returns(successful_series_response)

    result = @search.search_by_name_with_diacritics("Naïve Series")

    assert result[:success]
  end

  test "search_by_alias searches by alias field" do
    @mock_client.expects(:get)
      .with("series", {query: 'alias:Top\\ 100'})
      .returns(successful_series_response)

    result = @search.search_by_alias("Top 100")

    assert result[:success]
  end

  test "search_by_type searches by type field" do
    @mock_client.expects(:get)
      .with("series", {query: 'type:Release\\ group\\ series'})
      .returns(successful_series_response)

    result = @search.search_by_type("Release group series")

    assert result[:success]
  end

  test "search_by_tag searches by tag field" do
    @mock_client.expects(:get)
      .with("series", {query: "tag:ranking"})
      .returns(successful_series_response)

    result = @search.search_by_tag("ranking")

    assert result[:success]
  end

  test "search_by_comment searches by comment field" do
    @mock_client.expects(:get)
      .with("series", {query: 'comment:music\\ magazine'})
      .returns(successful_series_response)

    result = @search.search_by_comment("music magazine")

    assert result[:success]
  end

  test "search_release_group_series searches for Release group series type" do
    @mock_client.expects(:get)
      .with("series", {query: 'type:Release\\ group\\ series'})
      .returns(successful_series_response)

    result = @search.search_release_group_series

    assert result[:success]
  end

  test "search_release_group_series with name includes both criteria" do
    expected_query = 'type:Release\\ group\\ series AND series:Vice\'s\\ 100\\ Best'

    @mock_client.expects(:get)
      .with("series", {query: expected_query})
      .returns(successful_series_response)

    result = @search.search_release_group_series("Vice's 100 Best")

    assert result[:success]
  end

  test "search_by_name_and_type combines name and type search" do
    expected_query = 'series:Vice\'s\\ 100\\ Best AND type:Release\\ group\\ series'

    @mock_client.expects(:get)
      .with("series", {query: expected_query})
      .returns(successful_series_response)

    result = @search.search_by_name_and_type("Vice's 100 Best", "Release group series")

    assert result[:success]
  end

  test "browse_series_with_release_groups uses direct lookup with inc parameter" do
    series_mbid = "28cbc99a-875f-4139-b8b0-f1dd520ec62c"

    @mock_client.expects(:get)
      .with("series/#{series_mbid}", {inc: "release-group-rels"})
      .returns(successful_browse_response)

    result = @search.browse_series_with_release_groups(series_mbid)

    assert result[:success]
    assert_equal 1, result[:data]["count"]
    assert result[:data]["results"].first["relations"]
  end

  test "browse_series_with_release_groups includes additional options" do
    series_mbid = "28cbc99a-875f-4139-b8b0-f1dd520ec62c"
    options = {limit: 50, offset: 10}

    @mock_client.expects(:get)
      .with("series/#{series_mbid}", {inc: "release-group-rels", limit: 50, offset: 10})
      .returns(successful_browse_response)

    result = @search.browse_series_with_release_groups(series_mbid, options)

    assert result[:success]
  end

  test "browse_series_with_release_groups validates MBID format" do
    invalid_mbid = "not-a-valid-mbid"

    assert_raises(Music::Musicbrainz::QueryError) do
      @search.browse_series_with_release_groups(invalid_mbid)
    end
  end

  test "search performs general search with custom query" do
    @mock_client.expects(:get)
      .with("series", {query: 'series:100\\ Best AND type:Release\\ group\\ series'})
      .returns(successful_series_response)

    result = @search.search("series:100\\ Best AND type:Release\\ group\\ series")

    assert result[:success]
  end

  test "search includes pagination options" do
    @mock_client.expects(:get)
      .with("series", {query: "series:Vice", limit: 10, offset: 20})
      .returns(successful_series_response)

    result = @search.search("series:Vice", limit: 10, offset: 20)

    assert result[:success]
  end

  test "search_with_criteria builds complex queries" do
    criteria = {
      series: "Vice's 100 Best",
      type: "Release group series",
      tag: "ranking"
    }

    expected_query = 'series:Vice\'s\\ 100\\ Best AND type:Release\\ group\\ series AND tag:ranking'

    @mock_client.expects(:get)
      .with("series", {query: expected_query})
      .returns(successful_series_response)

    result = @search.search_with_criteria(criteria)

    assert result[:success]
  end

  test "search_with_criteria skips blank values" do
    criteria = {
      series: "Vice's 100 Best",
      type: "",
      tag: nil
    }

    @mock_client.expects(:get)
      .with("series", {query: 'series:Vice\'s\\ 100\\ Best'})
      .returns(successful_series_response)

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
    criteria = {series: "", type: nil}

    assert_raises(Music::Musicbrainz::QueryError) do
      @search.search_with_criteria(criteria)
    end
  end

  test "returns raw API response data without processing for search" do
    @mock_client.expects(:get)
      .with("series", {query: 'series:Vice\'s\\ 100\\ Best'})
      .returns(successful_series_response)

    result = @search.search_by_name("Vice's 100 Best")

    assert result[:success]
    # Should return raw data structure from API
    assert_equal "28cbc99a-875f-4139-b8b0-f1dd520ec62c", result[:data]["series"].first["id"]
    assert_equal "Vice's 100 Greatest Albums of All Time", result[:data]["series"].first["name"]
  end

  test "returns processed browse response data with results array" do
    series_mbid = "28cbc99a-875f-4139-b8b0-f1dd520ec62c"

    @mock_client.expects(:get)
      .with("series/#{series_mbid}", {inc: "release-group-rels"})
      .returns(successful_browse_response)

    result = @search.browse_series_with_release_groups(series_mbid)

    assert result[:success]
    # Browse response should be transformed to match search format
    assert_equal 1, result[:data]["count"]
    assert_equal 0, result[:data]["offset"]
    assert result[:data]["results"].is_a?(Array)
    assert_equal "28cbc99a-875f-4139-b8b0-f1dd520ec62c", result[:data]["results"].first["id"]
  end

  test "search handles API errors gracefully" do
    @mock_client.expects(:get)
      .raises(Music::Musicbrainz::NetworkError.new("Connection failed"))

    result = @search.search("series:Vice")

    refute result[:success]
    assert_includes result[:errors], "Connection failed"
    assert_equal "series", result[:metadata][:entity_type]
  end

  test "browse_series_with_release_groups handles API errors gracefully" do
    series_mbid = "28cbc99a-875f-4139-b8b0-f1dd520ec62c"

    @mock_client.expects(:get)
      .raises(Music::Musicbrainz::NetworkError.new("Series not found"))

    result = @search.browse_series_with_release_groups(series_mbid)

    refute result[:success]
    assert_includes result[:errors], "Series not found"
    assert_equal series_mbid, result[:metadata][:series_mbid]
  end

  test "find_by_mbid uses correct MBID field" do
    valid_mbid = "28cbc99a-875f-4139-b8b0-f1dd520ec62c"

    @mock_client.expects(:get)
      .with("series", {query: "sid:28cbc99a\\-875f\\-4139\\-b8b0\\-f1dd520ec62c"})
      .returns(successful_series_response)

    result = @search.find_by_mbid(valid_mbid)

    assert result[:success]
  end

  private

  def successful_series_response
    {
      success: true,
      data: {
        "count" => 1,
        "offset" => 0,
        "series" => [
          {
            "id" => "28cbc99a-875f-4139-b8b0-f1dd520ec62c",
            "name" => "Vice's 100 Greatest Albums of All Time",
            "disambiguation" => "music magazine ranking",
            "type" => "Release group series",
            "type-id" => "60b29b75-d77a-4cd7-a7e7-c290b4bb7f95",
            "score" => "100",
            "tags" => [
              {
                "count" => 1,
                "name" => "ranking"
              },
              {
                "count" => 1,
                "name" => "best-of"
              }
            ],
            "aliases" => [
              {
                "name" => "Vice Top 100",
                "sort-name" => "Vice Top 100",
                "type" => "Series name"
              }
            ]
          }
        ]
      },
      errors: [],
      metadata: {
        endpoint: "series",
        response_time: 0.145
      }
    }
  end

  def successful_browse_response
    {
      success: true,
      data: {
        "series" => {
          "id" => "28cbc99a-875f-4139-b8b0-f1dd520ec62c",
          "name" => "Vice's 100 Greatest Albums of All Time",
          "disambiguation" => "music magazine ranking",
          "type" => "Release group series",
          "type-id" => "60b29b75-d77a-4cd7-a7e7-c290b4bb7f95",
          "relations" => [
            {
              "type" => "part of",
              "type-id" => "b0d17366-7b64-4af5-bd41-c3d7bc5f2d5c",
              "direction" => "backward",
              "ordering-key" => 1,
              "begin" => nil,
              "end" => nil,
              "ended" => false,
              "target" => "b84ee12a-9f6e-3f70-afb2-5a9c40e74f4d",
              "release-group" => {
                "id" => "b84ee12a-9f6e-3f70-afb2-5a9c40e74f4d",
                "type-id" => "f529b476-6e62-324f-b0aa-1f3e33d313fc",
                "type" => "Album",
                "primary-type" => "Album",
                "title" => "Abbey Road",
                "first-release-date" => "1969-09-26",
                "artist-credit" => [
                  {
                    "name" => "The Beatles",
                    "artist" => {
                      "id" => "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d",
                      "name" => "The Beatles",
                      "sort-name" => "Beatles, The"
                    }
                  }
                ]
              }
            },
            {
              "type" => "part of",
              "type-id" => "b0d17366-7b64-4af5-bd41-c3d7bc5f2d5c",
              "direction" => "backward",
              "ordering-key" => 2,
              "begin" => nil,
              "end" => nil,
              "ended" => false,
              "target" => "1c5193b4-bdda-4d53-8cb4-c23732d70503",
              "release-group" => {
                "id" => "1c5193b4-bdda-4d53-8cb4-c23732d70503",
                "type-id" => "f529b476-6e62-324f-b0aa-1f3e33d313fc",
                "type" => "Album",
                "primary-type" => "Album",
                "title" => "Pet Sounds",
                "first-release-date" => "1966-05-16",
                "artist-credit" => [
                  {
                    "name" => "The Beach Boys",
                    "artist" => {
                      "id" => "618b6900-94b6-47cc-8b76-1b5e2a8fd5b1",
                      "name" => "The Beach Boys",
                      "sort-name" => "Beach Boys, The"
                    }
                  }
                ]
              }
            }
          ]
        },
        "created" => "2025-09-02T10:30:45.123Z"
      },
      errors: [],
      metadata: {
        endpoint: "series/28cbc99a-875f-4139-b8b0-f1dd520ec62c",
        response_time: 0.267
      }
    }
  end
end
