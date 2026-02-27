class Admin::Music::SongArtistsController < Admin::Music::BaseController
  include ArtistAssociationActions

  private

  def join_model_class = Music::SongArtist
  def param_key = :music_song_artist
  def parent_resource_name = :song
  def parent_policy_class = Music::SongPolicy
  def parent_path(resource) = admin_song_path(resource)
  def parent_frame_id = "song_artists_list"
  def artist_frame_id = "artist_songs_list"
  def parent_partial_path = "admin/music/songs/artists_list"
  def artist_partial_path = "admin/music/artists/songs_list"
end
