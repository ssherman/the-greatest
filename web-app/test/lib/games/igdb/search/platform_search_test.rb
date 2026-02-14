# frozen_string_literal: true

require "test_helper"

class Games::Igdb::Search::PlatformSearchTest < ActiveSupport::TestCase
  def setup
    @mock_client = mock("client")
    @search = Games::Igdb::Search::PlatformSearch.new(@mock_client)
  end

  test "endpoint returns platforms" do
    assert_equal "platforms", @search.endpoint
  end

  test "default_fields includes expected fields" do
    fields = @search.default_fields
    assert_includes fields, "name"
    assert_includes fields, "slug"
    assert_includes fields, "abbreviation"
  end

  test "search_by_name searches for platforms" do
    @mock_client.expects(:post)
      .with("platforms", includes('search "PlayStation"'))
      .returns(successful_response)

    result = @search.search_by_name("PlayStation")
    assert result[:success]
  end

  test "by_family filters by platform_family" do
    @mock_client.expects(:post)
      .with("platforms", includes("platform_family = 1"))
      .returns(successful_response)

    result = @search.by_family(1)
    assert result[:success]
  end

  private

  def successful_response
    {
      success: true,
      data: [{"id" => 48, "name" => "PlayStation 4", "slug" => "playstation-4"}],
      errors: [],
      metadata: {endpoint: "platforms", response_time: 0.123, status_code: 200}
    }
  end
end
