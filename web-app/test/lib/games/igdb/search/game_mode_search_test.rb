# frozen_string_literal: true

require "test_helper"

class Games::Igdb::Search::GameModeSearchTest < ActiveSupport::TestCase
  def setup
    @mock_client = mock("client")
    @search = Games::Igdb::Search::GameModeSearch.new(@mock_client)
  end

  test "endpoint returns game_modes" do
    assert_equal "game_modes", @search.endpoint
  end

  test "default_fields returns name and slug" do
    assert_equal %w[name slug], @search.default_fields
  end

  test "search works" do
    @mock_client.expects(:post)
      .with("game_modes", 'fields name, slug; search "multiplayer"; limit 10;')
      .returns(successful_response)

    result = @search.search("multiplayer")
    assert result[:success]
  end

  test "all works" do
    @mock_client.expects(:post)
      .with("game_modes", "fields name, slug; limit 10;")
      .returns(successful_response)

    result = @search.all
    assert result[:success]
  end

  private

  def successful_response
    {
      success: true,
      data: [{"id" => 2, "name" => "Multiplayer", "slug" => "multiplayer"}],
      errors: [],
      metadata: {endpoint: "game_modes", response_time: 0.1, status_code: 200}
    }
  end
end
