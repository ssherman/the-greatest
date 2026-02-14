# frozen_string_literal: true

require "test_helper"

class Games::Igdb::Search::KeywordSearchTest < ActiveSupport::TestCase
  def setup
    @mock_client = mock("client")
    @search = Games::Igdb::Search::KeywordSearch.new(@mock_client)
  end

  test "endpoint returns keywords" do
    assert_equal "keywords", @search.endpoint
  end

  test "default_fields returns name and slug" do
    assert_equal %w[name slug], @search.default_fields
  end

  test "search works" do
    @mock_client.expects(:post)
      .with("keywords", 'fields name, slug; search "open world"; limit 10;')
      .returns(successful_response)

    result = @search.search("open world")
    assert result[:success]
  end

  test "find_by_id works" do
    @mock_client.expects(:post)
      .with("keywords", "fields name, slug; where id = 121;")
      .returns(successful_response)

    result = @search.find_by_id(121)
    assert result[:success]
  end

  private

  def successful_response
    {
      success: true,
      data: [{"id" => 121, "name" => "Open world", "slug" => "open-world"}],
      errors: [],
      metadata: {endpoint: "keywords", response_time: 0.1, status_code: 200}
    }
  end
end
