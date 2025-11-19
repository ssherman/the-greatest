module Admin::ResourcesHelper
  def link_to_admin_album(album, options = {})
    return nil unless album
    link_to album.title, admin_album_path(album),
      options.reverse_merge(class: "link link-hover", data: {turbo_frame: "_top"})
  end

  def link_to_admin_song(song, options = {})
    return nil unless song
    link_to song.title, admin_song_path(song),
      options.reverse_merge(class: "link link-hover", data: {turbo_frame: "_top"})
  end

  def link_to_admin_artist(artist, options = {})
    return nil unless artist
    link_to artist.name, admin_artist_path(artist),
      options.reverse_merge(class: "link link-hover", data: {turbo_frame: "_top"})
  end

  def link_to_admin_artists(artists, options = {})
    return nil if artists.blank?

    limit = options.delete(:limit) || 3
    separator = options.delete(:separator) || ", "

    artists.first(limit).map { |artist| link_to_admin_artist(artist, options) }.join(separator).html_safe
  end
end
