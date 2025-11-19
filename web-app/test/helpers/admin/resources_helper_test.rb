require "test_helper"

class Admin::ResourcesHelperTest < ActionView::TestCase
  include Admin::ResourcesHelper

  setup do
    @album = music_albums(:dark_side_of_the_moon)
    @song = music_songs(:time)
    @artist = music_artists(:pink_floyd)
  end

  test "link_to_admin_album returns link with default options" do
    result = link_to_admin_album(@album)
    assert_includes result, @album.title
    assert_includes result, admin_album_path(@album)
    assert_includes result, 'class="link link-hover"'
    assert_includes result, 'data-turbo-frame="_top"'
  end

  test "link_to_admin_album returns nil for nil album" do
    assert_nil link_to_admin_album(nil)
  end

  test "link_to_admin_album accepts custom options" do
    result = link_to_admin_album(@album, class: "custom-class")
    assert_includes result, 'class="custom-class"'
  end

  test "link_to_admin_song returns link with default options" do
    result = link_to_admin_song(@song)
    assert_includes result, @song.title
    assert_includes result, admin_song_path(@song)
    assert_includes result, 'class="link link-hover"'
    assert_includes result, 'data-turbo-frame="_top"'
  end

  test "link_to_admin_song returns nil for nil song" do
    assert_nil link_to_admin_song(nil)
  end

  test "link_to_admin_artist returns link with default options" do
    result = link_to_admin_artist(@artist)
    assert_includes result, @artist.name
    assert_includes result, admin_artist_path(@artist)
    assert_includes result, 'class="link link-hover"'
    assert_includes result, 'data-turbo-frame="_top"'
  end

  test "link_to_admin_artist returns nil for nil artist" do
    assert_nil link_to_admin_artist(nil)
  end

  test "link_to_admin_artists returns multiple artist links" do
    artists = [@artist, music_artists(:roger_waters)]
    result = link_to_admin_artists(artists)

    assert_includes result, @artist.name
    assert_includes result, music_artists(:roger_waters).name
    assert_includes result, ", "
  end

  test "link_to_admin_artists limits to 3 artists by default" do
    artists = [
      @artist,
      music_artists(:roger_waters),
      music_artists(:david_gilmour),
      music_artists(:david_bowie)
    ]
    result = link_to_admin_artists(artists)

    assert_includes result, @artist.name
    assert_includes result, music_artists(:roger_waters).name
    assert_includes result, music_artists(:david_gilmour).name
    assert_not_includes result, music_artists(:david_bowie).name
  end

  test "link_to_admin_artists accepts custom limit" do
    artists = [
      @artist,
      music_artists(:roger_waters),
      music_artists(:david_gilmour)
    ]
    result = link_to_admin_artists(artists, limit: 1)

    assert_includes result, @artist.name
    assert_not_includes result, music_artists(:roger_waters).name
  end

  test "link_to_admin_artists accepts custom separator" do
    artists = [@artist, music_artists(:roger_waters)]
    result = link_to_admin_artists(artists, separator: " / ")

    assert_includes result, " / "
  end

  test "link_to_admin_artists returns nil for blank array" do
    assert_nil link_to_admin_artists([])
    assert_nil link_to_admin_artists(nil)
  end
end
