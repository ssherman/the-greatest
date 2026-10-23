class AlternateTitle < ApplicationRecord
  enum :source, {legacy: 0, merge: 1, ai_enrichment: 2, admin: 3, correction: 4}, prefix: :from
  enum :status, {kept: 0, removed: 1, review: 2}
  enum :verdict, {same_work: 0, not_same_work: 1}, prefix: true
  enum :category, {translation: 0, variant: 1, fuller_title: 2, short_title: 3, other_work: 4, volume_or_part: 5, combined_edition: 6, junk: 7}, prefix: true
  enum :decided_by, {ai: 0, admin: 1, correction: 2}, prefix: true

  belongs_to :titleable, polymorphic: true
  belongs_to :ai_chat, optional: true
  belongs_to :decided_by_user, class_name: "User", optional: true

  validates :title, :normalized_title, presence: true
  validates :normalized_title, uniqueness: {scope: [:titleable_type, :titleable_id]}

  before_validation :set_normalized_title
  # A row that becomes removed again has not been through the undo pass for
  # this removal, whatever stamp an earlier removal left.
  before_save { self.undo_checked_at = nil if will_save_change_to_status?(to: "removed") }

  scope :listed, -> { where(status: [:kept, :review]).order(:id) }
  scope :unjudged, -> { where(status: :kept, verdict: nil) }

  # The comparison form of a title: quotes and names normalized, lowercased.
  # Nil for a blank title. Services::Books::Verification::Check.normalize uses
  # the same rule, and a test keeps the two in agreement.
  def self.normalize(text)
    return nil if text.blank?

    ::Services::Text::NameNormalizer.call(::Services::Text::QuoteNormalizer.call(text.to_s)).downcase.presence
  end

  private

  def set_normalized_title
    self.normalized_title = self.class.normalize(title)
  end
end
