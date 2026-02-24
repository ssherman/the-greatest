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

  test "search_by_name uses broadened game_type filter" do
    @mock_client.expects(:post)
      .with("games", includes("game_type = (0,4,8,9,10,11)"))
      .returns(successful_game_response)

    result = @search.search_by_name("Donkey Kong")
    assert result[:success]
  end

  test "search_by_name returns primary results without fallback" do
    @mock_client.expects(:post)
      .with("games", anything)
      .returns(successful_game_response)
      .once

    result = @search.search_by_name("The Legend of Zelda")
    assert result[:success]
    assert_equal 1, result[:data].length
  end

  test "search_by_name with custom limit" do
    @mock_client.expects(:post)
      .with("games", includes("limit 25"))
      .returns(successful_game_response)

    result = @search.search_by_name("Zelda", limit: 25)
    assert result[:success]
  end

  test "search_by_name falls back to name-contains when primary returns empty" do
    @mock_client.expects(:post)
      .with("games", includes('search "Pokemon Yellow"'))
      .returns(empty_response)

    @mock_client.expects(:post)
      .with("games", includes('name ~ *"Pokemon Yellow"*'))
      .returns(successful_game_response)

    result = @search.search_by_name("Pokemon Yellow")
    assert result[:success]
    assert result[:data].any?
  end

  test "search_by_name name-contains fallback includes game_type filter" do
    @mock_client.expects(:post)
      .with("games", anything)
      .returns(empty_response)

    @mock_client.expects(:post)
      .with("games", all_of(includes('name ~ *"test"*'), includes("game_type = (0,4,8,9,10,11)")))
      .returns(successful_game_response)

    @search.search_by_name("test")
  end

  test "search_by_name falls back to alternative_names when both primary and name-contains return empty" do
    # Primary search - empty
    @mock_client.expects(:post)
      .with("games", includes('search "Pokemon Yellow"'))
      .returns(empty_response)

    # Name-contains fallback - empty
    @mock_client.expects(:post)
      .with("games", includes('name ~ *"Pokemon Yellow"*'))
      .returns(empty_response)

    # Alternative names lookup
    @mock_client.expects(:post)
      .with("alternative_names", includes('name ~ *"Pokemon Yellow"*'))
      .returns(alternative_names_response)

    # Fetch games by IDs
    @mock_client.expects(:post)
      .with("games", includes("id = (1456)"))
      .returns(pokemon_yellow_response)

    result = @search.search_by_name("Pokemon Yellow")
    assert result[:success]
    assert_equal "Pokemon Yellow Version: Special Pikachu Edition", result[:data].first["name"]
  end

  test "search_by_name returns empty success when all three searches return empty" do
    # Primary - empty
    @mock_client.expects(:post)
      .with("games", includes('search "xyznonexistent"'))
      .returns(empty_response)

    # Name-contains - empty
    @mock_client.expects(:post)
      .with("games", includes('name ~ *"xyznonexistent"*'))
      .returns(empty_response)

    # Alternative names - empty
    @mock_client.expects(:post)
      .with("alternative_names", anything)
      .returns(empty_response)

    result = @search.search_by_name("xyznonexistent")
    assert result[:success]
    assert_equal [], result[:data]
  end

  test "search_by_name alternative_names fallback handles API error gracefully" do
    @mock_client.expects(:post)
      .with("games", anything)
      .returns(empty_response)

    @mock_client.expects(:post)
      .with("games", includes("name ~"))
      .returns(empty_response)

    @mock_client.expects(:post)
      .with("alternative_names", anything)
      .raises(Games::Igdb::Exceptions::NetworkError.new("Connection failed"))

    result = @search.search_by_name("test")
    assert_equal false, result[:success]
    assert result[:errors].any?
  end

  test "search_by_name alternative_names deduplicates game IDs" do
    @mock_client.expects(:post)
      .with("games", anything)
      .returns(empty_response)

    @mock_client.expects(:post)
      .with("games", includes("name ~"))
      .returns(empty_response)

    # Two alt names pointing to the same game
    @mock_client.expects(:post)
      .with("alternative_names", anything)
      .returns({success: true, data: [{"game" => 100}, {"game" => 100}, {"game" => 200}], errors: [], metadata: {}})

    @mock_client.expects(:post)
      .with("games", includes("id = (100,200)"))
      .returns(successful_game_response)

    @search.search_by_name("test")
  end

  test "search_by_name alternative_names fallback passes caller limit" do
    @mock_client.expects(:post)
      .with("games", all_of(includes("search"), includes("limit 25")))
      .returns(empty_response)

    @mock_client.expects(:post)
      .with("games", all_of(includes("name ~"), includes("limit 25")))
      .returns(empty_response)

    @mock_client.expects(:post)
      .with("alternative_names", includes("limit 25"))
      .returns(alternative_names_response)

    @mock_client.expects(:post)
      .with("games", includes("id = (1456)"))
      .returns(pokemon_yellow_response)

    @search.search_by_name("Pokemon Yellow", limit: 25)
  end

  test "search_by_name alternative_names fallback applies game_type filter" do
    @mock_client.expects(:post)
      .with("games", anything)
      .returns(empty_response)

    @mock_client.expects(:post)
      .with("games", includes("name ~"))
      .returns(empty_response)

    @mock_client.expects(:post)
      .with("alternative_names", anything)
      .returns(alternative_names_response)

    @mock_client.expects(:post)
      .with("games", all_of(includes("id = (1456)"), includes("game_type = (0,4,8,9,10,11)")))
      .returns(pokemon_yellow_response)

    result = @search.search_by_name("Pokemon Yellow")
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

  def empty_response
    {success: true, data: [], errors: [], metadata: {}}
  end

  def alternative_names_response
    {
      success: true,
      data: [{"game" => 1456}],
      errors: [],
      metadata: {endpoint: "alternative_names", response_time: 0.123, status_code: 200}
    }
  end

  def pokemon_yellow_response
    {
      success: true,
      data: [
        {"id" => 1456, "name" => "Pokemon Yellow Version: Special Pikachu Edition", "slug" => "pokemon-yellow-version-special-pikachu-edition"}
      ],
      errors: [],
      metadata: {endpoint: "games", response_time: 0.234, status_code: 200}
    }
  end
end
