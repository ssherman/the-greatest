# frozen_string_literal: true

require "test_helper"

class Games::Igdb::Search::CoverSearchTest < ActiveSupport::TestCase
  def setup
    @mock_client = mock("client")
    @search = Games::Igdb::Search::CoverSearch.new(@mock_client)
  end

  test "endpoint returns covers" do
    assert_equal "covers", @search.endpoint
  end

  test "find_by_game_id queries by game id" do
    @mock_client.expects(:post)
      .with("covers", includes("game = 7346"))
      .returns(successful_response)

    result = @search.find_by_game_id(7346)
    assert result[:success]
  end

  test "find_by_game_id validates id" do
    assert_raises(Games::Igdb::Exceptions::QueryError) do
      @search.find_by_game_id(-1)
    end
  end

  test "find_by_game_ids queries multiple games" do
    @mock_client.expects(:post)
      .with("covers", includes("game = (1,2,3)"))
      .returns(successful_response)

    result = @search.find_by_game_ids([1, 2, 3])
    assert result[:success]
  end

  test "image_url builds correct URL with default size" do
    url = @search.image_url("co1abc")
    assert_equal "https://images.igdb.com/igdb/image/upload/t_cover_big/co1abc.jpg", url
  end

  test "image_url builds correct URL with thumb size" do
    url = @search.image_url("co1abc", size: Games::Igdb::Search::CoverSearch::SIZE_THUMB)
    assert_equal "https://images.igdb.com/igdb/image/upload/t_thumb/co1abc.jpg", url
  end

  test "image_url builds correct URL with cover_small size" do
    url = @search.image_url("co1abc", size: Games::Igdb::Search::CoverSearch::SIZE_COVER_SMALL)
    assert_equal "https://images.igdb.com/igdb/image/upload/t_cover_small/co1abc.jpg", url
  end

  test "image_url builds correct URL with 720p size" do
    url = @search.image_url("co1abc", size: Games::Igdb::Search::CoverSearch::SIZE_720P)
    assert_equal "https://images.igdb.com/igdb/image/upload/t_720p/co1abc.jpg", url
  end

  test "image_url builds correct URL with 1080p size" do
    url = @search.image_url("co1abc", size: Games::Igdb::Search::CoverSearch::SIZE_1080P)
    assert_equal "https://images.igdb.com/igdb/image/upload/t_1080p/co1abc.jpg", url
  end

  test "size constants have correct values" do
    assert_equal "t_thumb", Games::Igdb::Search::CoverSearch::SIZE_THUMB
    assert_equal "t_cover_small", Games::Igdb::Search::CoverSearch::SIZE_COVER_SMALL
    assert_equal "t_cover_big", Games::Igdb::Search::CoverSearch::SIZE_COVER_BIG
    assert_equal "t_720p", Games::Igdb::Search::CoverSearch::SIZE_720P
    assert_equal "t_1080p", Games::Igdb::Search::CoverSearch::SIZE_1080P
  end

  private

  def successful_response
    {
      success: true,
      data: [{"id" => 100, "image_id" => "co1abc", "game" => 7346}],
      errors: [],
      metadata: {endpoint: "covers", response_time: 0.1, status_code: 200}
    }
  end
end
