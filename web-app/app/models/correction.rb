# == Schema Information
#
# Table name: corrections
#
#  id               :bigint           not null, primary key
#  correctable_type :string           not null
#  notes            :text
#  resolution_notes :text
#  resolved_at      :datetime
#  status           :integer          default(0), not null
#  submitter_ip     :string
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  correctable_id   :bigint           not null
#  resolved_by_id   :bigint
#  user_id          :bigint
#
# Indexes
#
#  index_corrections_on_correctable            (correctable_type,correctable_id)
#  index_corrections_on_resolved_by_id         (resolved_by_id)
#  index_corrections_on_status_and_created_at  (status,created_at)
#  index_corrections_on_user_id                (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (resolved_by_id => users.id)
#  fk_rails_...  (user_id => users.id)
#
class Correction < ApplicationRecord
  # Generous enough that no real submission is affected -- the longest legacy note
  # is well under a thousand characters -- while bounding an anonymous public write
  # endpoint that anyone can post to.
  MAX_NOTES_LENGTH = 10_000

  belongs_to :correctable, polymorphic: true
  belongs_to :user, optional: true
  belongs_to :resolved_by, class_name: "User", optional: true
  has_many :correction_fields, dependent: :destroy

  # No `approved` state. Legacy declared one alongside `rejected` and set neither
  # for two years; nothing sits between approving a field and writing it. `resolved`
  # means the admin acted -- by applying fields, or by fixing something the notes
  # described by hand. The field rows record which.
  enum :status, {pending: 0, resolved: 1, rejected: 2}

  normalizes :notes, with: ->(value) { value.presence }

  validates :notes, length: {maximum: MAX_NOTES_LENGTH}
  validate :notes_or_fields_present

  scope :recent, -> { order(created_at: :desc, id: :desc) }

  private

  # `correction_fields.any?` reads the loaded association target on an unsaved
  # record and queries on a persisted one -- both are the answer we want.
  def notes_or_fields_present
    return if notes.present? || correction_fields.any?

    errors.add(:base, "Tell us what's wrong, or propose a change to at least one field")
  end
end
