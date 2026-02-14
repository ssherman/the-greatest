# frozen_string_literal: true

require "test_helper"

class Games::Igdb::Search::ThemeSearchTest < ActiveSupport::TestCase
  def setup
    @mock_client = mock("client")
    @search = Games::Igdb::Search::ThemeSearch.new(@mock_client)
  end

  test "endpoint returns themes" do
    assert_equal "themes", @search.endpoint
  end

  test "default_fields returns name and slug" do
    assert_equal %w[name slug], @search.default_fields
  end

  test "search works" do
    @mock_client.expects(:post)
      .with("themes", 'fields name, slug; search "fantasy"; limit 10;')
      .returns(successful_response)

    result = @search.search("fantasy")
    assert result[:success]
  end

  test "find_by_id works" do
    @mock_client.expects(:post)
      .with("themes", "fields name, slug; where id = 17;")
      .returns(successful_response)

    result = @search.find_by_id(17)
    assert result[:success]
  end

  private

  def successful_response
    {
      success: true,
      data: [{"id" => 17, "name" => "Fantasy", "slug" => "fantasy"}],
      errors: [],
      metadata: {endpoint: "themes", response_time: 0.1, status_code: 200}
    }
  end
end
