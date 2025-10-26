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

  def music_albums_lists_path_with_rc(ranking_configuration = nil)
    if ranking_configuration && !ranking_configuration.default_primary?
      music_albums_lists_path(ranking_configuration_id: ranking_configuration.id)
    else
      music_albums_lists_path
    end
  end

  def music_songs_lists_path_with_rc(ranking_configuration = nil)
    if ranking_configuration && !ranking_configuration.default_primary?
      music_songs_lists_path(ranking_configuration_id: ranking_configuration.id)
    else
      music_songs_lists_path
    end
  end

  def music_album_list_path_with_rc(list, ranking_configuration = nil)
    if ranking_configuration && !ranking_configuration.default_primary?
      music_album_list_path(list, ranking_configuration_id: ranking_configuration.id)
    else
      music_album_list_path(list)
    end
  end

  def music_song_list_path_with_rc(list, ranking_configuration = nil)
    if ranking_configuration && !ranking_configuration.default_primary?
      music_song_list_path(list, ranking_configuration_id: ranking_configuration.id)
    else
      music_song_list_path(list)
    end
  end

  def link_to_album_list(list, ranking_configuration = nil, **options, &block)
    path = music_album_list_path_with_rc(list, ranking_configuration)
    if block_given?
      link_to path, **options, &block
    else
      link_to list.name, path, **options
    end
  end

  def link_to_song_list(list, ranking_configuration = nil, **options, &block)
    path = music_song_list_path_with_rc(list, ranking_configuration)
    if block_given?
      link_to path, **options, &block
    else
      link_to list.name, path, **options
    end
  end

  def music_category_path_with_rc(category, ranking_configuration = nil)
    music_category_path(category)
  end

  def music_artist_category_path_with_rc(category, ranking_configuration = nil)
    if ranking_configuration && !ranking_configuration.default_primary?
      music_artist_category_path(category, ranking_configuration_id: ranking_configuration.id)
    else
      music_artist_category_path(category)
    end
  end

  def music_album_category_path_with_rc(category, ranking_configuration = nil)
    if ranking_configuration && !ranking_configuration.default_primary?
      music_album_category_path(category, ranking_configuration_id: ranking_configuration.id)
    else
      music_album_category_path(category)
    end
  end

  def link_to_category(category, ranking_configuration = nil, **options, &block)
    path = music_category_path_with_rc(category, ranking_configuration)
    if block_given?
      link_to path, **options, &block
    else
      link_to category.name, path, **options
    end
  end
end
