require "test_helper"

module Music
  class SongsControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev.thegreatestmusic.org"
    end

    test "should get show with default ranking configuration" do
      get song_path(music_songs(:time))
      assert_response :success
      assert_select "h1", "Time"
      assert_select "title", /Time/
    end

    test "should get show with specific ranking configuration" do
      get song_path(music_songs(:time), ranking_configuration_id: ranking_configurations(:music_songs_global).id)
      assert_response :success
      assert_select "h1", "Time"
    end

    test "should get show by slug" do
      get song_path("time")
      assert_response :success
      assert_select "h1", "Time"
    end

    test "should display song metadata" do
      get song_path(music_songs(:time))
      assert_response :success
      assert_select ".badge", /Released: 1973/
      assert_select ".badge", /07:01/
    end

    test "should return 404 for non-existent song" do
      get song_path("non-existent-song")
      assert_response :not_found
    end
  end
end
