module Music::DefaultHelper
  def music_album_path_with_rc(album, ranking_configuration = nil)
    if ranking_configuration && !ranking_configuration.default_primary?
      album_path(album, ranking_configuration_id: ranking_configuration.id)
    else
      album_path(album)
    end
  end

  def music_song_path_with_rc(song, ranking_configuration = nil)
    if ranking_configuration && !ranking_configuration.default_primary?
      song_path(song, ranking_configuration_id: ranking_configuration.id)
    else
      song_path(song)
    end
  end

  def link_to_album(album, ranking_configuration = nil, **options, &block)
    path = music_album_path_with_rc(album, ranking_configuration)
    if block_given?
      link_to path, **options, &block
    else
      link_to album.title, path, **options
    end
  end

  def link_to_song(song, ranking_configuration = nil, **options, &block)
    path = music_song_path_with_rc(song, ranking_configuration)
    if block_given?
      link_to path, **options, &block
    else
      link_to song.title, path, **options
    end
  end

  def link_to_artist(artist, **options, &block)
    if block_given?
      link_to artist_path(artist), **options, &block
    else
      link_to artist.name, artist_path(artist), **options
    end
  end
end
