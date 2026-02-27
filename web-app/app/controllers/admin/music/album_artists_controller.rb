class Admin::Music::AlbumArtistsController < Admin::Music::BaseController
  include ArtistAssociationActions

  private

  def join_model_class = Music::AlbumArtist
  def param_key = :music_album_artist
  def parent_resource_name = :album
  def parent_policy_class = Music::AlbumPolicy
  def parent_path(resource) = admin_album_path(resource)
  def parent_frame_id = "album_artists_list"
  def artist_frame_id = "artist_albums_list"
  def parent_partial_path = "admin/music/albums/artists_list"
  def artist_partial_path = "admin/music/artists/albums_list"
end
