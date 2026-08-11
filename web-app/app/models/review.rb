# == Schema Information
#
# Table name: reviews
#
#  id              :bigint           not null, primary key
#  body            :text
#  rating          :integer          not null
#  reviewable_type :string           not null
#  title           :string
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  reviewable_id   :bigint           not null
#  user_id         :bigint           not null
#
# Indexes
#
#  index_reviews_on_reviewable              (reviewable_type,reviewable_id)
#  index_reviews_on_reviewable_with_body    (reviewable_type,reviewable_id) WHERE (body IS NOT NULL)
#  index_reviews_on_user_and_reviewable     (user_id,reviewable_type,reviewable_id) UNIQUE
#  index_reviews_on_user_id_and_created_at  (user_id,created_at)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
class Review < ApplicationRecord
  # Generous enough that no legitimate legacy review is affected -- the longest is
  # 20,030 characters -- while catching the one 462KB XSS-fuzz paste. Enforced as a
  # validation, not by the sanitizer, so an over-long paste is a user-visible error
  # rather than silent data loss.
  MAX_BODY_LENGTH = 25_000

  # The longest legacy title is 100 characters; 255 clears all real data with room to
  # spare.
  MAX_TITLE_LENGTH = 255

  belongs_to :user
  belongs_to :reviewable, polymorphic: true

  normalizes :title, with: ->(value) { value.presence }

  before_validation :sanitize_body

  validates :rating, presence: true, numericality: {
    only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 5
  }
  validates :title, length: {maximum: MAX_TITLE_LENGTH}
  validate :validate_body_length
  validates :user_id, uniqueness: {scope: [:reviewable_type, :reviewable_id]}

  # Honest only because the sanitizer and the reviews_body_not_blank check constraint
  # make an empty-string body unrepresentable. Legacy's identical scope returned 5,177
  # empty-string bodies that rendered as blank review cards.
  scope :with_body, -> { where.not(body: nil) }
  # `id: :desc` is a tiebreaker, not a preference -- Postgres gives no ordering
  # guarantee among ties, and rating has only 5 distinct values / created_at arrives in
  # bulk-import clusters, so ties are the norm on the paginated surfaces these back.
  scope :by_rating, -> { order(rating: :desc, id: :desc) }
  scope :recent, -> { order(created_at: :desc, id: :desc) }

  # Bulk paths (the increment-2 migrator) bypass this by design and call
  # SummaryRecalculator.backfill_all! once at the end instead.
  after_commit :recalculate_summary

  private

  def sanitize_body
    # Captured before BodySanitizer touches body, for validate_body_length below --
    # sanitizing runs before any validation (before_validation callbacks always
    # precede validations, regardless of declaration order), so by the time a plain
    # `validates :body, length:` would run, body is no longer what was submitted.
    @body_length_before_sanitizing = body.to_s.length
    self.body = Services::Reviews::BodySanitizer.call(body)
  end

  # Checked against what was SUBMITTED, not what BodySanitizer produced from it.
  # BodySanitizer adds markup on write -- wrapping blank-line-separated plain text in
  # <p>/<br> (see Services::Reviews::BodySanitizer#paragraphize), expanding a typed
  # <spoiler> into a <span class="review-spoiler"> -- and either can push a body that
  # fit the textarea's maxlength=25000 over MAX_BODY_LENGTH on its own. Validating the
  # sanitized body's length would then reject a submission the form told the author
  # was acceptable. The textarea's maxlength constrains what was submitted, not what
  # BodySanitizer produces from it, so that is the only length that can fail here
  # without contradicting the form -- and per BodySanitizer's header comment ("Does not
  # truncate... an over-long paste raises a user-visible error"), the paste IS the
  # submitted value, so this still catches a genuinely over-long paste exactly as
  # before: an input already over MAX_BODY_LENGTH before sanitizing was always over the
  # limit as typed, regardless of what sanitizing does to it afterward.
  def validate_body_length
    return unless @body_length_before_sanitizing.to_i > MAX_BODY_LENGTH

    errors.add(:body, :too_long, count: MAX_BODY_LENGTH)
  end

  # Type and id rather than the object: this fires on destroy too, where the
  # association may no longer load from a frozen record.
  def recalculate_summary
    Services::Reviews::SummaryRecalculator.recalculate(reviewable_type, reviewable_id)
  end
end
