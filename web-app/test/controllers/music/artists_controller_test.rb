require "test_helper"

module Music
  class ArtistsControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev.thegreatestmusic.org"
    end

    test "should get show with default ranking configuration" do
      get artist_path(music_artists(:pink_floyd))
      assert_response :success
      assert_select "h1", "Pink Floyd"
      assert_select "title", /Pink Floyd/
    end

    test "should get show with specific ranking configuration" do
      get artist_path(music_artists(:pink_floyd), ranking_configuration_id: ranking_configurations(:music_albums_global).id)
      assert_response :success
      assert_select "h1", "Pink Floyd"
    end

    test "should get show by slug" do
      get artist_path("pink-floyd")
      assert_response :success
      assert_select "h1", "Pink Floyd"
    end

    test "should display artist metadata" do
      get artist_path(music_artists(:pink_floyd))
      assert_response :success
      assert_select "p", /English progressive rock band/
    end

    test "should return 404 for non-existent artist" do
      get artist_path("non-existent-artist")
      assert_response :not_found
    end
  end
end
