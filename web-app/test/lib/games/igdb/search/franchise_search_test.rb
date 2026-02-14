# frozen_string_literal: true

require "test_helper"

class Games::Igdb::Search::FranchiseSearchTest < ActiveSupport::TestCase
  def setup
    @mock_client = mock("client")
    @search = Games::Igdb::Search::FranchiseSearch.new(@mock_client)
  end

  test "endpoint returns franchises" do
    assert_equal "franchises", @search.endpoint
  end

  test "default_fields includes expected fields" do
    assert_equal %w[name slug games], @search.default_fields
  end

  test "search works" do
    @mock_client.expects(:post)
      .with("franchises", 'fields name, slug, games; search "Zelda"; limit 10;')
      .returns(successful_response)

    result = @search.search("Zelda")
    assert result[:success]
  end

  test "find_by_id works" do
    @mock_client.expects(:post)
      .with("franchises", "fields name, slug, games; where id = 596;")
      .returns(successful_response)

    result = @search.find_by_id(596)
    assert result[:success]
  end

  private

  def successful_response
    {
      success: true,
      data: [{"id" => 596, "name" => "The Legend of Zelda", "slug" => "the-legend-of-zelda"}],
      errors: [],
      metadata: {endpoint: "franchises", response_time: 0.1, status_code: 200}
    }
  end
end
