require "test_helper"

module Music
  class AlbumsControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev.thegreatestmusic.org"
    end

    test "should get show with default ranking configuration" do
      get album_path(music_albums(:dark_side_of_the_moon))
      assert_response :success
      assert_select "h1", "The Dark Side of the Moon"
      assert_select "title", /The Dark Side of the Moon/
    end

    test "should get show with specific ranking configuration" do
      get album_path(music_albums(:dark_side_of_the_moon), ranking_configuration_id: ranking_configurations(:music_albums_global).id)
      assert_response :success
      assert_select "h1", "The Dark Side of the Moon"
    end

    test "should get show by slug" do
      get album_path("the-dark-side-of-the-moon")
      assert_response :success
      assert_select "h1", "The Dark Side of the Moon"
    end

    test "should display album metadata" do
      get album_path(music_albums(:dark_side_of_the_moon))
      assert_response :success
      assert_select ".badge", /Released: 1973/
    end

    test "should return 404 for non-existent album" do
      get album_path("non-existent-album")
      assert_response :not_found
    end
  end
end
