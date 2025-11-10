require "test_helper"

module Admin
  module Music
    class AlbumArtistsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @album = music_albums(:dark_side_of_the_moon)
        @artist = music_artists(:pink_floyd)
        @album_artist = music_album_artists(:dark_side_pink_floyd)
        @another_artist = music_artists(:the_beatles)

        host! Rails.application.config.domains[:music]
        sign_in_as(@admin_user, stub_auth: true)
      end

      test "should create album_artist from album context" do
        assert_difference("::Music::AlbumArtist.count") do
          post admin_album_album_artists_path(@album),
            params: {music_album_artist: {album_id: @album.id, artist_id: @another_artist.id, position: 2}}
        end

        assert_redirected_to admin_album_path(@album)
      end

      test "should create album_artist from artist context" do
        another_album = music_albums(:wish_you_were_here)

        assert_difference("::Music::AlbumArtist.count") do
          post admin_artist_album_artists_path(@another_artist),
            params: {music_album_artist: {album_id: another_album.id, artist_id: @another_artist.id, position: 1}}
        end

        assert_redirected_to admin_artist_path(@another_artist)
      end

      test "should not create duplicate album_artist" do
        assert_no_difference("::Music::AlbumArtist.count") do
          post admin_album_album_artists_path(@album),
            params: {music_album_artist: {album_id: @album.id, artist_id: @artist.id, position: 2}}
        end

        assert_redirected_to admin_album_path(@album)
      end

      test "should update album_artist position" do
        patch admin_album_artist_path(@album_artist),
          params: {music_album_artist: {position: 5}}

        @album_artist.reload
        assert_equal 5, @album_artist.position
        assert_redirected_to admin_album_path(@album)
      end

      test "should not update with invalid position" do
        patch admin_album_artist_path(@album_artist),
          params: {music_album_artist: {position: nil}}

        assert_redirected_to admin_album_path(@album)
      end

      test "should destroy album_artist" do
        assert_difference("::Music::AlbumArtist.count", -1) do
          delete admin_album_artist_path(@album_artist)
        end

        assert_redirected_to admin_album_path(@album)
      end

      test "should require admin or editor role for create" do
        regular_user = users(:regular_user)
        sign_in_as(regular_user, stub_auth: true)

        post admin_album_album_artists_path(@album),
          params: {music_album_artist: {album_id: @album.id, artist_id: @another_artist.id, position: 2}}

        assert_redirected_to music_root_path
      end

      test "should require admin or editor role for update" do
        regular_user = users(:regular_user)
        sign_in_as(regular_user, stub_auth: true)

        patch admin_album_artist_path(@album_artist),
          params: {music_album_artist: {position: 5}}

        assert_redirected_to music_root_path
      end

      test "should require admin or editor role for destroy" do
        regular_user = users(:regular_user)
        sign_in_as(regular_user, stub_auth: true)

        delete admin_album_artist_path(@album_artist)

        assert_redirected_to music_root_path
      end

      test "should determine context from album_id param" do
        post admin_album_album_artists_path(@album),
          params: {music_album_artist: {album_id: @album.id, artist_id: @another_artist.id, position: 2}}

        assert_redirected_to admin_album_path(@album)
      end

      test "should determine context from artist_id param" do
        another_album = music_albums(:wish_you_were_here)

        post admin_artist_album_artists_path(@another_artist),
          params: {music_album_artist: {album_id: another_album.id, artist_id: @another_artist.id, position: 1}}

        assert_redirected_to admin_artist_path(@another_artist)
      end

      test "should infer artist context from referer on update" do
        patch admin_album_artist_path(@album_artist),
          params: {music_album_artist: {position: 3}},
          headers: {"HTTP_REFERER" => admin_artist_url(@artist)}

        assert_redirected_to admin_artist_path(@artist)
      end

      test "should infer album context from referer on update" do
        patch admin_album_artist_path(@album_artist),
          params: {music_album_artist: {position: 3}},
          headers: {"HTTP_REFERER" => admin_album_url(@album)}

        assert_redirected_to admin_album_path(@album)
      end

      test "should infer artist context from referer on destroy" do
        delete admin_album_artist_path(@album_artist),
          headers: {"HTTP_REFERER" => admin_artist_url(@artist)}

        assert_redirected_to admin_artist_path(@artist)
      end

      test "should infer album context from referer on destroy" do
        album_artist = music_album_artists(:wish_you_were_here_pink_floyd)

        delete admin_album_artist_path(album_artist),
          headers: {"HTTP_REFERER" => admin_album_url(album_artist.album)}

        assert_redirected_to admin_album_path(album_artist.album)
      end
    end
  end
end
