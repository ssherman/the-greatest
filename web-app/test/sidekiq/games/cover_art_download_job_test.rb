# frozen_string_literal: true

require "test_helper"

class Games::CoverArtDownloadJobTest < ActiveSupport::TestCase
  def setup
    @game = games_games(:breath_of_the_wild)
    @game.identifiers.create!(
      identifier_type: :games_igdb_id,
      value: "7346"
    )
  end

  test "perform downloads cover art from IGDB CDN" do
    cover_search = mock
    cover_search.expects(:find_by_game_id).with(7346).returns(
      success: true,
      data: [{"image_id" => "abc123"}]
    )
    cover_search.expects(:image_url).with("abc123", size: ::Games::Igdb::Search::CoverSearch::SIZE_1080P).returns(
      "https://images.igdb.com/igdb/image/upload/t_1080p/abc123.jpg"
    )

    ::Games::Igdb::Search::CoverSearch.stubs(:new).returns(cover_search)

    # Mock file download
    tempfile = Tempfile.new(["cover", ".jpg"])
    tempfile.write("fake image data")
    tempfile.rewind

    Down.stubs(:download).returns(tempfile)

    Games::CoverArtDownloadJob.new.perform(@game.id)

    @game.reload
    assert @game.images.where(primary: true).exists?
  ensure
    tempfile&.close
    tempfile&.unlink
  end

  test "perform skips when game already has primary image" do
    # Create existing primary image
    image = @game.images.build(primary: true)
    image.file.attach(io: StringIO.new("fake"), filename: "test.jpg", content_type: "image/jpeg")
    image.save!

    # Should not call IGDB API
    ::Games::Igdb::Search::CoverSearch.expects(:new).never

    Games::CoverArtDownloadJob.new.perform(@game.id)
  end

  test "perform handles missing IGDB identifier gracefully" do
    game_without_id = games_games(:half_life_2)

    # Should not call IGDB API
    ::Games::Igdb::Search::CoverSearch.expects(:new).never

    # Should not raise
    Games::CoverArtDownloadJob.new.perform(game_without_id.id)
  end

  test "perform handles IGDB API failure gracefully" do
    cover_search = mock
    cover_search.expects(:find_by_game_id).with(7346).returns(
      success: false,
      errors: ["API error"]
    )

    ::Games::Igdb::Search::CoverSearch.stubs(:new).returns(cover_search)

    # Should not raise
    Games::CoverArtDownloadJob.new.perform(@game.id)
    refute @game.images.where(primary: true).exists?
  end

  test "perform handles missing cover art data gracefully" do
    cover_search = mock
    cover_search.expects(:find_by_game_id).with(7346).returns(
      success: true,
      data: []
    )

    ::Games::Igdb::Search::CoverSearch.stubs(:new).returns(cover_search)

    # Should not raise
    Games::CoverArtDownloadJob.new.perform(@game.id)
    refute @game.images.where(primary: true).exists?
  end

  test "perform handles download failure gracefully" do
    cover_search = mock
    cover_search.expects(:find_by_game_id).with(7346).returns(
      success: true,
      data: [{"image_id" => "abc123"}]
    )
    cover_search.expects(:image_url).returns("https://images.igdb.com/abc123.jpg")

    ::Games::Igdb::Search::CoverSearch.stubs(:new).returns(cover_search)
    Down.stubs(:download).raises(Down::Error, "Download failed")

    # Should not raise
    Games::CoverArtDownloadJob.new.perform(@game.id)
    refute @game.images.where(primary: true).exists?
  end
end
