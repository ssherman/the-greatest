# == Schema Information
#
# Table name: music_song_artists
#
#  id         :bigint           not null, primary key
#  position   :integer          default(1)
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  artist_id  :bigint           not null
#  song_id    :bigint           not null
#
# Indexes
#
#  index_music_song_artists_on_artist_id              (artist_id)
#  index_music_song_artists_on_song_id                (song_id)
#  index_music_song_artists_on_song_id_and_artist_id  (song_id,artist_id) UNIQUE
#  index_music_song_artists_on_song_id_and_position   (song_id,position)
#
# Foreign Keys
#
#  fk_rails_...  (artist_id => music_artists.id)
#  fk_rails_...  (song_id => music_songs.id)
#
require "test_helper"

class Music::SongArtistTest < ActiveSupport::TestCase
  # test "the truth" do
  #   assert true
  # end
end
