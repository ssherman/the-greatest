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

  # The same bound, applied to the FIELD values -- Services::Corrections::Submission
  # enforces these, because a field value is stored in correction_fields.new_value
  # (jsonb) rather than on this row, so a length validation here could not see it.
  #
  # They exist for the same reason MAX_NOTES_LENGTH does, only more so:
  # /suggest-correction is an anonymous POST anyone can make, its rate limit keys
  # on visitor_ip which the origin will believe from a spoofed CF-Connecting-IP
  # if a request ever reaches it off-edge, and this repo ships no Rack or nginx
  # body limit. Without these, one request stores an arbitrarily large blob per
  # field and an arbitrarily long array.
  #
  # Sized off the real corpus rather than guessed -- 446 migrated corrections and
  # the 139,850 book descriptions they were migrated against:
  #
  #   MAX_FIELD_VALUE_LENGTH  The longest value ever SUBMITTED for a non-description
  #                           field is 108 characters (a page_range). The longest
  #                           value on a real correctable record -- which matters
  #                           because the form prefills every input with the
  #                           current value -- is 444 (a Music::Album title);
  #                           books_books.subtitle reaches 431. 1,000 is more than
  #                           double the largest real value.
  #
  #   MAX_TEXT_VALUE_LENGTH   A :text field means the description, which is
  #                           prefilled and edited in place, so the cap must clear
  #                           the longest description any correctable record has:
  #                           64,664 characters on a Books::Book (Games::Game tops
  #                           out at 4,351, Music::Album at 813). 100,000 clears
  #                           every one of them with room to spare. Books::Author
  #                           reaches 153,244 but is not correctable.
  #
  #   MAX_ARRAY_ELEMENTS      The longest alternate_titles list on a real book is
  #                           66 entries, and the form prefills all 66. 100 is the
  #                           nearest round number above that.
  MAX_FIELD_VALUE_LENGTH = 1_000
  MAX_TEXT_VALUE_LENGTH = 100_000
  MAX_ARRAY_ELEMENTS = 100

  belongs_to :correctable, polymorphic: true
  belongs_to :user, optional: true
  belongs_to :resolved_by, class_name: "User", optional: true
  has_many :correction_fields, dependent: :destroy

  # For the admin review form, which submits per-field decisions, and for tests
  # that build a correction and its fields in one call.
  accepts_nested_attributes_for :correction_fields

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
