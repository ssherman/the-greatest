# frozen_string_literal: true

require "test_helper"

class Games::Igdb::Search::CompanySearchTest < ActiveSupport::TestCase
  def setup
    @mock_client = mock("client")
    @search = Games::Igdb::Search::CompanySearch.new(@mock_client)
  end

  test "endpoint returns companies" do
    assert_equal "companies", @search.endpoint
  end

  test "default_fields includes expected fields" do
    fields = @search.default_fields
    assert_includes fields, "name"
    assert_includes fields, "slug"
    assert_includes fields, "developed"
    assert_includes fields, "published"
  end

  test "search_by_name searches for companies" do
    @mock_client.expects(:post)
      .with("companies", includes('search "Nintendo"'))
      .returns(successful_response)

    result = @search.search_by_name("Nintendo")
    assert result[:success]
  end

  test "find_with_details returns company with expanded fields" do
    @mock_client.expects(:post)
      .with("companies", includes("developed.name"))
      .returns(successful_response)

    result = @search.find_with_details(70)
    assert result[:success]
  end

  test "find_with_details validates id" do
    assert_raises(Games::Igdb::Exceptions::QueryError) do
      @search.find_with_details(-1)
    end
  end

  private

  def successful_response
    {
      success: true,
      data: [{"id" => 70, "name" => "Nintendo", "slug" => "nintendo"}],
      errors: [],
      metadata: {endpoint: "companies", response_time: 0.123, status_code: 200}
    }
  end
end
