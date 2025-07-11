# == Schema Information
#
# Table name: music_tracks
#
#  id            :bigint           not null, primary key
#  length_secs   :integer
#  medium_number :integer          default(1), not null
#  notes         :text
#  position      :integer          not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  release_id    :bigint           not null
#  song_id       :bigint           not null
#
# Indexes
#
#  index_music_tracks_on_release_id               (release_id)
#  index_music_tracks_on_release_medium_position  (release_id,medium_number,position) UNIQUE
#  index_music_tracks_on_song_id                  (song_id)
#
# Foreign Keys
#
#  fk_rails_...  (release_id => music_releases.id)
#  fk_rails_...  (song_id => music_songs.id)
#
class Music::Track < ApplicationRecord
  belongs_to :release, class_name: "Music::Release"
  belongs_to :song, class_name: "Music::Song"
  # has_many :credits, as: :creditable

  validates :release, presence: true
  validates :song, presence: true
  validates :medium_number, presence: true, numericality: {only_integer: true, greater_than: 0}
  validates :position, presence: true, numericality: {only_integer: true, greater_than: 0}
  validates :length_secs, numericality: {only_integer: true, greater_than: 0}, allow_nil: true

  scope :ordered, -> { order(:medium_number, :position) }
  scope :on_medium, ->(num) { where(medium_number: num) }

  # medium_number: The sequential number of the medium (disc, record, tape, etc.) in a multi-part release.
end
