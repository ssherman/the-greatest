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
