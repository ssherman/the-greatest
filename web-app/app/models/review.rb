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
    #
    # Memoized against @sanitized_body -- this method's own last output -- rather
    # than recaptured on every call, or Review#valid? stops being idempotent.
    # before_validation runs on every validation pass, not just the first: call
    # #valid? twice on the same object (or save it, then validate it again later)
    # and, without this guard, the second pass would find `body` already holding
    # the FIRST pass's own sanitized output -- paragraph/spoiler markup this code
    # added -- and wrongly recapture that markup-inflated length as if it were a
    # fresh submission. `body != @sanitized_body` is false exactly when nothing new
    # has been assigned since the last time this method ran, so the original
    # submission length survives untouched across repeat passes; it only recomputes
    # when body has genuinely changed (a real new assignment, not our own prior
    # output echoed back).
    if body != @sanitized_body
      @body_length_before_sanitizing = body.to_s.length
    end

    @sanitized_body = Services::Reviews::BodySanitizer.call(body)
    self.body = @sanitized_body
  end

  # Checked against what was SUBMITTED, not what BodySanitizer produced from it, and
  # only when body is actually part of what's being saved. BodySanitizer adds markup
  # on write -- wrapping blank-line-separated plain text in <p>/<br> (see
  # Services::Reviews::BodySanitizer#paragraphize), expanding a typed <spoiler> into
  # a <span class="review-spoiler"> -- and either can push a body that fit the
  # textarea's maxlength=25000 over MAX_BODY_LENGTH on its own. Validating the
  # sanitized body's length whenever body is present would then reject a submission
  # the form told the author was acceptable -- and would keep rejecting it on every
  # later save, since .call's own idempotency (BLOCK_MARKUP, span absent from the
  # write-time allowlist) means re-sanitizing an already-stored over-length body just
  # reproduces the same length. That would make a record this code already accepted
  # once permanently unsavable by any path that doesn't rewrite body -- a rating-only
  # edit, a console fix-up, increment 5's admin edit.
  #
  # will_save_change_to_body? -- checked here, after sanitize_body has set the final
  # value -- is false for exactly that case: a persisted record whose sanitized body
  # equals what's already stored has nothing new to reject, so the check is skipped
  # and the save goes through regardless of how long the *stored* body already is.
  # It is true whenever body is genuinely changing, including every new record (nil
  # is never equal to real content), so the guarantee this validation exists for --
  # a body that fit the textarea cannot fail purely because of markup this code
  # added -- still holds on every save that actually writes a body. And per
  # BodySanitizer's header comment ("Does not truncate... an over-long paste raises a
  # user-visible error"), the paste IS the submitted value, so a genuinely over-long
  # paste is still caught exactly as before: an input already over MAX_BODY_LENGTH
  # before sanitizing was always over the limit as typed, regardless of what
  # sanitizing does to it afterward.
  def validate_body_length
    return unless will_save_change_to_body?
    return unless @body_length_before_sanitizing.to_i > MAX_BODY_LENGTH

    errors.add(:body, :too_long, count: MAX_BODY_LENGTH)
  end

  # Type and id rather than the object: this fires on destroy too, where the
  # association may no longer load from a frozen record.
  def recalculate_summary
    Services::Reviews::SummaryRecalculator.recalculate(reviewable_type, reviewable_id)
  end
end
