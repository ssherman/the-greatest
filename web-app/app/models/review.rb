# == Schema Information
#
# Table name: reviews
#
#  id              :bigint           not null, primary key
#  body            :text
#  rating          :integer
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

  # Goodreads' five-bar rule: round to the nearest whole star, ties round down,
  # and everything up to 1.5 is a 1. Integer-cast so grouped counts key on
  # Integers. Every bucketed consumer (summaries, the My Reviews filter and
  # stats) uses this or rating_bucket, never its own rounding.
  RATING_BUCKET_SQL = "GREATEST(1, CEIL(reviews.rating - 0.5))::integer"

  def self.rating_bucket(value)
    return nil if value.nil?

    [1, (value.to_d - BigDecimal("0.5")).ceil].max
  end

  # The one way a rating becomes text. BigDecimal#to_s is "0.375e1", so a raw
  # interpolation is a bug, not a style choice.
  def self.format_rating(value)
    return nil if value.nil?

    text = value.to_d.round(2).to_s("F")
    text.sub(/0+\z/, "").sub(/\.\z/, "")
  end

  belongs_to :user
  belongs_to :reviewable, polymorphic: true

  normalizes :title, with: ->(value) { value.presence }

  before_validation :sanitize_body

  # Optional: Goodreads, and so an import, allows a written review with no stars.
  # rating_or_body_present is what stops an empty review. Fractional since
  # Goodreads went to quarter stars; 0 is Goodreads' "not rated", never a rating.
  validates :rating, numericality: {greater_than: 0, less_than_or_equal_to: 5}, allow_nil: true
  validates :title, length: {maximum: MAX_TITLE_LENGTH}
  validates :body, length: {maximum: MAX_BODY_LENGTH}
  validates :user_id, uniqueness: {scope: [:reviewable_type, :reviewable_id]}
  validate :rating_or_body_present

  # Honest only because the sanitizer and the reviews_body_not_blank check constraint
  # make an empty-string body unrepresentable. Legacy's identical scope returned 5,177
  # empty-string bodies that rendered as blank review cards.
  scope :with_body, -> { where.not(body: nil) }
  # `id: :desc` is a tiebreaker, not a preference -- Postgres gives no ordering
  # guarantee among ties, and rating has only 5 distinct values / created_at arrives in
  # bulk-import clusters, so ties are the norm on the paginated surfaces these back.
  # NULLS LAST: an unrated review has no place in a by-rating ordering, and Postgres
  # sorts NULL first under DESC by default.
  scope :by_rating, -> { order(Arel.sql("reviews.rating DESC NULLS LAST"), id: :desc) }
  scope :recent, -> { order(created_at: :desc, id: :desc) }

  # Bulk paths (the increment-2 migrator) bypass this by design and call
  # SummaryRecalculator.backfill_all! once at the end instead.
  after_commit :recalculate_summary

  def formatted_rating
    self.class.format_rating(rating)
  end

  private

  # Runs after sanitize_body (a before_validation), so a body the sanitizer reduced
  # to nil does not count. Mirrors the reviews_rating_or_body check constraint.
  def rating_or_body_present
    return if rating.present? || body.present?

    errors.add(:base, :rating_or_body_missing, message: "A review needs a rating or some text")
  end

  # BodySanitizer.call sanitizes but never transforms, so this is idempotent: running
  # it again on its own output returns the same string. That is why no length has to be
  # captured before it runs, and why validating twice gives the same answer.
  def sanitize_body
    self.body = Services::Reviews::BodySanitizer.call(body)
  end

  # Type and id rather than the object: this fires on destroy too, where the
  # association may no longer load from a frozen record.
  def recalculate_summary
    Services::Reviews::SummaryRecalculator.recalculate(reviewable_type, reviewable_id)
  end
end
