# frozen_string_literal: true

require "test_helper"

class Games::Igdb::Search::GenreSearchTest < ActiveSupport::TestCase
  def setup
    @mock_client = mock("client")
    @search = Games::Igdb::Search::GenreSearch.new(@mock_client)
  end

  test "endpoint returns genres" do
    assert_equal "genres", @search.endpoint
  end

  test "default_fields returns name and slug" do
    assert_equal %w[name slug], @search.default_fields
  end

  test "find_by_id works" do
    @mock_client.expects(:post)
      .with("genres", "fields name, slug; where id = 12;")
      .returns(successful_response)

    result = @search.find_by_id(12)
    assert result[:success]
  end

  test "search works" do
    @mock_client.expects(:post)
      .with("genres", 'fields name, slug; search "RPG"; limit 10;')
      .returns(successful_response)

    result = @search.search("RPG")
    assert result[:success]
  end

  test "all works" do
    @mock_client.expects(:post)
      .with("genres", "fields name, slug; limit 50;")
      .returns(successful_response)

    result = @search.all(limit: 50)
    assert result[:success]
  end

  private

  def successful_response
    {
      success: true,
      data: [{"id" => 12, "name" => "Role-playing (RPG)", "slug" => "role-playing-rpg"}],
      errors: [],
      metadata: {endpoint: "genres", response_time: 0.1, status_code: 200}
    }
  end
end
