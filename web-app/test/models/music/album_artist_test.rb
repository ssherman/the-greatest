# == Schema Information
#
# Table name: music_album_artists
#
#  id         :bigint           not null, primary key
#  position   :integer          default(1)
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  album_id   :bigint           not null
#  artist_id  :bigint           not null
#
# Indexes
#
#  index_music_album_artists_on_album_id                (album_id)
#  index_music_album_artists_on_album_id_and_artist_id  (album_id,artist_id) UNIQUE
#  index_music_album_artists_on_album_id_and_position   (album_id,position)
#  index_music_album_artists_on_artist_id               (artist_id)
#
# Foreign Keys
#
#  fk_rails_...  (album_id => music_albums.id)
#  fk_rails_...  (artist_id => music_artists.id)
#
require "test_helper"

class Music::AlbumArtistTest < ActiveSupport::TestCase
  # test "the truth" do
  #   assert true
  # end
end
