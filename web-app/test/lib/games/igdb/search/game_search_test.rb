# frozen_string_literal: true

require "test_helper"

class Games::Igdb::Search::GameSearchTest < ActiveSupport::TestCase
  def setup
    @mock_client = mock("client")
    @search = Games::Igdb::Search::GameSearch.new(@mock_client)
  end

  test "endpoint returns games" do
    assert_equal "games", @search.endpoint
  end

  test "default_fields includes expected fields" do
    fields = @search.default_fields
    assert_includes fields, "name"
    assert_includes fields, "slug"
    assert_includes fields, "cover"
    assert_includes fields, "genres"
    assert_includes fields, "platforms"
  end

  test "search_by_name searches with game_type filter" do
    expected_query = 'fields name, slug, summary, first_release_date, rating, total_rating, cover, genres, platforms, game_modes, themes, keywords, player_perspectives, franchises, involved_companies; search "The Legend of Zelda"; where game_type = 0; limit 10;'

    @mock_client.expects(:post)
      .with("games", expected_query)
      .returns(successful_game_response)

    result = @search.search_by_name("The Legend of Zelda")
    assert result[:success]
  end

  test "search_by_name with custom limit" do
    @mock_client.expects(:post)
      .with("games", anything)
      .returns(successful_game_response)

    result = @search.search_by_name("Zelda", limit: 25)
    assert result[:success]
  end

  test "find_with_details returns game with expanded fields" do
    @mock_client.expects(:post)
      .with("games", anything)
      .returns(successful_game_detail_response)

    result = @search.find_with_details(7346)
    assert result[:success]
  end

  test "find_with_details validates id" do
    assert_raises(Games::Igdb::Exceptions::QueryError) do
      @search.find_with_details(-1)
    end
  end

  test "find_with_details query includes expanded fields" do
    @mock_client.expects(:post).with("games", includes("cover.image_id")).returns(successful_game_detail_response)
    @search.find_with_details(7346)
  end

  test "find_with_details query includes genre expansion" do
    @mock_client.expects(:post).with("games", includes("genres.name")).returns(successful_game_detail_response)
    @search.find_with_details(7346)
  end

  test "by_platform filters by platform id" do
    @mock_client.expects(:post)
      .with("games", includes("platforms = (48)"))
      .returns(successful_game_response)

    result = @search.by_platform(48)
    assert result[:success]
  end

  test "handles empty results" do
    @mock_client.expects(:post)
      .returns({success: true, data: [], errors: [], metadata: {}})

    result = @search.search_by_name("nonexistent game xyz")
    assert result[:success]
    assert_equal [], result[:data]
  end

  private

  def successful_game_response
    {
      success: true,
      data: [
        {"id" => 7346, "name" => "The Legend of Zelda: Breath of the Wild", "slug" => "the-legend-of-zelda-breath-of-the-wild"}
      ],
      errors: [],
      metadata: {endpoint: "games", response_time: 0.234, status_code: 200}
    }
  end

  def successful_game_detail_response
    {
      success: true,
      data: [
        {
          "id" => 7346,
          "name" => "The Legend of Zelda: Breath of the Wild",
          "cover" => {"image_id" => "co1abc"},
          "genres" => [{"name" => "Adventure"}],
          "platforms" => [{"name" => "Nintendo Switch"}]
        }
      ],
      errors: [],
      metadata: {endpoint: "games", response_time: 0.345, status_code: 200}
    }
  end
end
