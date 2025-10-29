# frozen_string_literal: true

require "test_helper"

module Music
  class SearchesControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev.thegreatestmusic.org"
    end

    test "should get index with blank query" do
      get search_path
      assert_response :success
    end

    test "should get index with empty query parameter" do
      get search_path(q: "")
      assert_response :success
    end

    test "should handle no results without error" do
      ::Search::Music::Search::ArtistGeneral.stubs(:call).returns([])
      ::Search::Music::Search::AlbumGeneral.stubs(:call).returns([])
      ::Search::Music::Search::SongGeneral.stubs(:call).returns([])

      get search_path(q: "nonexistentartist")
      assert_response :success
    end

    test "should handle artist results without error" do
      artist = music_artists(:the_beatles)
      artist_results = [{id: artist.id.to_s, score: 10.0, source: {name: artist.name}}]

      ::Search::Music::Search::ArtistGeneral.stubs(:call).returns(artist_results)
      ::Search::Music::Search::AlbumGeneral.stubs(:call).returns([])
      ::Search::Music::Search::SongGeneral.stubs(:call).returns([])

      get search_path(q: "Beatles")
      assert_response :success
    end

    test "should handle album results without error" do
      album = music_albums(:dark_side_of_the_moon)
      album_results = [{id: album.id.to_s, score: 10.0, source: {title: album.title}}]

      ::Search::Music::Search::ArtistGeneral.stubs(:call).returns([])
      ::Search::Music::Search::AlbumGeneral.stubs(:call).returns(album_results)
      ::Search::Music::Search::SongGeneral.stubs(:call).returns([])

      get search_path(q: "Dark Side")
      assert_response :success
    end

    test "should handle song results without error" do
      song = music_songs(:time)
      song_results = [{id: song.id.to_s, score: 10.0, source: {title: song.title}}]

      ::Search::Music::Search::ArtistGeneral.stubs(:call).returns([])
      ::Search::Music::Search::AlbumGeneral.stubs(:call).returns([])
      ::Search::Music::Search::SongGeneral.stubs(:call).returns(song_results)

      get search_path(q: "Time")
      assert_response :success
    end

    test "should handle mixed results without error" do
      artist = music_artists(:the_beatles)
      album = music_albums(:dark_side_of_the_moon)
      song = music_songs(:time)

      artist_results = [{id: artist.id.to_s, score: 5.0, source: {name: artist.name}}]
      album_results = [{id: album.id.to_s, score: 8.0, source: {title: album.title}}]
      song_results = [{id: song.id.to_s, score: 10.0, source: {title: song.title}}]

      ::Search::Music::Search::ArtistGeneral.stubs(:call).returns(artist_results)
      ::Search::Music::Search::AlbumGeneral.stubs(:call).returns(album_results)
      ::Search::Music::Search::SongGeneral.stubs(:call).returns(song_results)

      get search_path(q: "music")
      assert_response :success
    end

    test "should call search with correct size parameters" do
      ::Search::Music::Search::ArtistGeneral.expects(:call).with("test", size: 25).returns([])
      ::Search::Music::Search::AlbumGeneral.expects(:call).with("test", size: 25).returns([])
      ::Search::Music::Search::SongGeneral.expects(:call).with("test", size: 10).returns([])

      get search_path(q: "test")
      assert_response :success
    end

    test "should handle special characters in query without error" do
      ::Search::Music::Search::ArtistGeneral.stubs(:call).returns([])
      ::Search::Music::Search::AlbumGeneral.stubs(:call).returns([])
      ::Search::Music::Search::SongGeneral.stubs(:call).returns([])

      get search_path(q: "AC/DC & More!")
      assert_response :success
    end

    test "should handle duplicate IDs without error" do
      artist = music_artists(:the_beatles)

      # Mock search to return duplicate IDs
      artist_results = [
        {id: artist.id.to_s, score: 10.0, source: {name: artist.name}},
        {id: artist.id.to_s, score: 9.0, source: {name: artist.name}}
      ]

      ::Search::Music::Search::ArtistGeneral.stubs(:call).returns(artist_results)
      ::Search::Music::Search::AlbumGeneral.stubs(:call).returns([])
      ::Search::Music::Search::SongGeneral.stubs(:call).returns([])

      get search_path(q: "Beatles")
      assert_response :success
    end
  end
end
