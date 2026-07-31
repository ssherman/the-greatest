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

    test "show renders the album's primary description" do
      album = music_albums(:dark_side_of_the_moon)
      get album_path(album)

      assert_response :success
      assert_includes response.body, descriptions(:dark_side_ai).content
    end

    test "show renders successfully for an album with no description" do
      album = music_albums(:wish_you_were_here)
      assert_empty album.descriptions

      get album_path(album)
      assert_response :success
    end
  end
end
