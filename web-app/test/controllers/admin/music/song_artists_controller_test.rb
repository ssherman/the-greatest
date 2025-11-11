require "test_helper"

module Admin
  module Music
    class SongArtistsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @song = music_songs(:time)
        @artist = music_artists(:pink_floyd)
        @song_artist = music_song_artists(:time_pink_floyd)
        @another_artist = music_artists(:the_beatles)

        host! Rails.application.config.domains[:music]
        sign_in_as(@admin_user, stub_auth: true)
      end

      test "should create song_artist from song context" do
        assert_difference("::Music::SongArtist.count") do
          post admin_song_song_artists_path(@song),
            params: {music_song_artist: {song_id: @song.id, artist_id: @another_artist.id, position: 2}}
        end

        assert_redirected_to admin_song_path(@song)
      end

      test "should create song_artist from artist context" do
        another_song = music_songs(:money)

        assert_difference("::Music::SongArtist.count") do
          post admin_artist_song_artists_path(@another_artist),
            params: {music_song_artist: {song_id: another_song.id, artist_id: @another_artist.id, position: 1}}
        end

        assert_redirected_to admin_artist_path(@another_artist)
      end

      test "should not create duplicate song_artist" do
        assert_no_difference("::Music::SongArtist.count") do
          post admin_song_song_artists_path(@song),
            params: {music_song_artist: {song_id: @song.id, artist_id: @artist.id, position: 2}}
        end

        assert_redirected_to admin_song_path(@song)
      end

      test "should update song_artist position" do
        patch admin_song_artist_path(@song_artist),
          params: {music_song_artist: {position: 5}}

        @song_artist.reload
        assert_equal 5, @song_artist.position
        assert_redirected_to admin_song_path(@song)
      end

      test "should not update with invalid position" do
        patch admin_song_artist_path(@song_artist),
          params: {music_song_artist: {position: nil}}

        assert_redirected_to admin_song_path(@song)
      end

      test "should destroy song_artist" do
        assert_difference("::Music::SongArtist.count", -1) do
          delete admin_song_artist_path(@song_artist)
        end

        assert_redirected_to admin_song_path(@song)
      end

      test "should require admin or editor role for create" do
        regular_user = users(:regular_user)
        sign_in_as(regular_user, stub_auth: true)

        post admin_song_song_artists_path(@song),
          params: {music_song_artist: {song_id: @song.id, artist_id: @another_artist.id, position: 2}}

        assert_redirected_to music_root_path
      end

      test "should require admin or editor role for update" do
        regular_user = users(:regular_user)
        sign_in_as(regular_user, stub_auth: true)

        patch admin_song_artist_path(@song_artist),
          params: {music_song_artist: {position: 5}}

        assert_redirected_to music_root_path
      end

      test "should require admin or editor role for destroy" do
        regular_user = users(:regular_user)
        sign_in_as(regular_user, stub_auth: true)

        delete admin_song_artist_path(@song_artist)

        assert_redirected_to music_root_path
      end

      test "should determine context from song_id param" do
        post admin_song_song_artists_path(@song),
          params: {music_song_artist: {song_id: @song.id, artist_id: @another_artist.id, position: 2}}

        assert_redirected_to admin_song_path(@song)
      end

      test "should determine context from artist_id param" do
        another_song = music_songs(:money)

        post admin_artist_song_artists_path(@another_artist),
          params: {music_song_artist: {song_id: another_song.id, artist_id: @another_artist.id, position: 1}}

        assert_redirected_to admin_artist_path(@another_artist)
      end

      test "should infer artist context from referer on update" do
        patch admin_song_artist_path(@song_artist),
          params: {music_song_artist: {position: 3}},
          headers: {"HTTP_REFERER" => admin_artist_url(@artist)}

        assert_redirected_to admin_artist_path(@artist)
      end

      test "should infer song context from referer on update" do
        patch admin_song_artist_path(@song_artist),
          params: {music_song_artist: {position: 3}},
          headers: {"HTTP_REFERER" => admin_song_url(@song)}

        assert_redirected_to admin_song_path(@song)
      end

      test "should infer artist context from referer on destroy" do
        delete admin_song_artist_path(@song_artist),
          headers: {"HTTP_REFERER" => admin_artist_url(@artist)}

        assert_redirected_to admin_artist_path(@artist)
      end

      test "should infer song context from referer on destroy" do
        song_artist = music_song_artists(:wish_you_were_here_pink_floyd)

        delete admin_song_artist_path(song_artist),
          headers: {"HTTP_REFERER" => admin_song_url(song_artist.song)}

        assert_redirected_to admin_song_path(song_artist.song)
      end
    end
  end
end
