# frozen_string_literal: true

require "test_helper"

class Games::Igdb::Search::PlayerPerspectiveSearchTest < ActiveSupport::TestCase
  def setup
    @mock_client = mock("client")
    @search = Games::Igdb::Search::PlayerPerspectiveSearch.new(@mock_client)
  end

  test "endpoint returns player_perspectives" do
    assert_equal "player_perspectives", @search.endpoint
  end

  test "default_fields returns name and slug" do
    assert_equal %w[name slug], @search.default_fields
  end

  test "search works" do
    @mock_client.expects(:post)
      .with("player_perspectives", 'fields name, slug; search "first person"; limit 10;')
      .returns(successful_response)

    result = @search.search("first person")
    assert result[:success]
  end

  test "find_by_id works" do
    @mock_client.expects(:post)
      .with("player_perspectives", "fields name, slug; where id = 1;")
      .returns(successful_response)

    result = @search.find_by_id(1)
    assert result[:success]
  end

  test "all works" do
    @mock_client.expects(:post)
      .with("player_perspectives", "fields name, slug; limit 10;")
      .returns(successful_response)

    result = @search.all
    assert result[:success]
  end

  private

  def successful_response
    {
      success: true,
      data: [{"id" => 1, "name" => "First person", "slug" => "first-person"}],
      errors: [],
      metadata: {endpoint: "player_perspectives", response_time: 0.1, status_code: 200}
    }
  end
end
