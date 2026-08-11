require "test_helper"

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
class ReviewTest < ActiveSupport::TestCase
  test "belongs to a polymorphic reviewable" do
    assert_equal Books::Book, reviews(:regular_user_war_and_peace).reviewable.class
  end

  test "belongs to a user" do
    assert_equal users(:regular_user), reviews(:regular_user_war_and_peace).user
  end

  test "requires a rating" do
    review = Review.new(user: users(:regular_user), reviewable: books_books(:got))
    assert_not review.valid?
    assert_includes review.errors[:rating], "can't be blank"
  end

  test "rejects a rating below 1" do
    review = Review.new(user: users(:regular_user), reviewable: books_books(:got), rating: 0)
    assert_not review.valid?
  end

  test "rejects a rating above 5" do
    review = Review.new(user: users(:regular_user), reviewable: books_books(:got), rating: 6)
    assert_not review.valid?
  end

  test "accepts a rating with no body or title" do
    review = Review.new(user: users(:regular_user), reviewable: books_books(:got), rating: 4)
    assert review.valid?
  end

  test "sanitizes the body before validation" do
    review = Review.new(
      user: users(:regular_user), reviewable: books_books(:got), rating: 4,
      body: "good <script>alert('xss')</script>"
    )
    review.valid?
    assert_not_includes review.body, "<script"
  end

  test "normalizes a whitespace-only body to nil" do
    review = Review.new(
      user: users(:regular_user), reviewable: books_books(:got), rating: 4, body: "   "
    )
    review.valid?
    assert_nil review.body
  end

  test "normalizes an image-only body to nil" do
    review = Review.new(
      user: users(:regular_user), reviewable: books_books(:got), rating: 4,
      body: %(<img src="https://example.test/x.png">)
    )
    review.valid?
    assert_nil review.body
  end

  test "normalizes a blank title to nil" do
    review = Review.new(
      user: users(:regular_user), reviewable: books_books(:got), rating: 4, title: "  "
    )
    review.valid?
    assert_nil review.title
  end

  test "rejects a body longer than MAX_BODY_LENGTH" do
    review = Review.new(
      user: users(:regular_user), reviewable: books_books(:got), rating: 4,
      body: "a" * (Review::MAX_BODY_LENGTH + 1)
    )
    assert_not review.valid?
    assert_includes review.errors[:body], "is too long (maximum is 25000 characters)"
  end

  test "allows a body exactly at MAX_BODY_LENGTH" do
    review = Review.new(
      user: users(:regular_user), reviewable: books_books(:got), rating: 4,
      body: "a" * Review::MAX_BODY_LENGTH
    )
    assert review.valid?
  end

  # Regression: paragraphize adds ~7 characters of <p></p> markup per paragraph, so a
  # plain-text body the textarea's maxlength=25000 accepted could come out of
  # BodySanitizer.call over MAX_BODY_LENGTH and 422 on something the form told the
  # author was fine. The raw submission here is exactly at the limit; only the
  # *stored* body, after conversion, goes over it.
  test "allows a raw body exactly at MAX_BODY_LENGTH even when paragraph conversion pushes the stored body over it" do
    raw = ("a" * 12_499) + "\n\n" + ("a" * 12_499)
    assert_equal Review::MAX_BODY_LENGTH, raw.length

    review = Review.new(user: users(:regular_user), reviewable: books_books(:got), rating: 4, body: raw)

    assert review.valid?
    assert_operator review.body.length, :>, Review::MAX_BODY_LENGTH
  end

  # The other side of the same boundary: a raw submission genuinely over the limit --
  # not just inflated by markup this code added -- must still be rejected, with
  # newlines present so paragraph conversion is actually in play (unlike the
  # newline-free "rejects a body longer than MAX_BODY_LENGTH" test above).
  test "rejects a raw body one character over MAX_BODY_LENGTH even with paragraph breaks" do
    raw = ("a" * 12_500) + "\n\n" + ("a" * 12_499)
    assert_equal Review::MAX_BODY_LENGTH + 1, raw.length

    review = Review.new(user: users(:regular_user), reviewable: books_books(:got), rating: 4, body: raw)

    assert_not review.valid?
    assert_includes review.errors[:body], "is too long (maximum is 25000 characters)"
  end

  # Regression: before_validation runs on every validation pass, not just the
  # first, so validating the same object twice used to re-derive "the submitted
  # length" from the FIRST pass's own sanitized output (paragraph markup this code
  # added) instead of the original submission -- a boundary body validated true,
  # then false on the very next pass on the same object, with nothing having
  # changed. #valid? must give the same answer both times.
  test "validating the same boundary-length review twice gives the same answer" do
    raw = ("a" * 12_499) + "\n\n" + ("a" * 12_499)
    review = Review.new(user: users(:regular_user), reviewable: books_books(:got), rating: 4, body: raw)

    first_result = review.valid?
    second_result = review.valid?

    assert first_result
    assert_equal first_result, second_result
  end

  # The other half of the same regression: a record the app already created and
  # accepted -- its *stored* body over MAX_BODY_LENGTH purely from paragraph markup,
  # exactly like the review above once saved -- must stay savable by a path that
  # never touches body at all, such as an admin correcting the rating.
  test "a persisted boundary-length review stays savable when only the rating changes" do
    raw = ("a" * 12_499) + "\n\n" + ("a" * 12_499)
    created = Review.create!(user: users(:regular_user), reviewable: books_books(:got), rating: 4, body: raw)
    assert_operator created.body.length, :>, Review::MAX_BODY_LENGTH

    reloaded = Review.find(created.id)
    reloaded.rating = 2

    assert reloaded.save
    assert_equal 2, reloaded.reload.rating
  end

  test "rejects a title longer than MAX_TITLE_LENGTH" do
    review = Review.new(
      user: users(:regular_user), reviewable: books_books(:got), rating: 4,
      title: "a" * (Review::MAX_TITLE_LENGTH + 1)
    )
    assert_not review.valid?
    assert_includes review.errors[:title], "is too long (maximum is 255 characters)"
  end

  test "allows a title exactly at MAX_TITLE_LENGTH" do
    review = Review.new(
      user: users(:regular_user), reviewable: books_books(:got), rating: 4,
      title: "a" * Review::MAX_TITLE_LENGTH
    )
    assert review.valid?
  end

  test "allows one review per user per reviewable" do
    duplicate = Review.new(
      user: users(:regular_user),
      reviewable: reviews(:regular_user_war_and_peace).reviewable,
      rating: 2
    )
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:user_id], "has already been taken"
  end

  test "allows the same user to review a different book" do
    review = Review.new(user: users(:regular_user), reviewable: books_books(:got), rating: 2)
    assert review.valid?
  end

  test "with_body returns only reviews that have text" do
    book = books_books(:war_and_peace)
    assert_equal 2, Review.where(reviewable: book).with_body.count
  end

  test "by_rating orders highest first" do
    ratings = Review.where(reviewable: books_books(:war_and_peace)).by_rating.pluck(:rating)
    assert_equal [5, 4, 4], ratings
  end

  test "recent orders newest first" do
    book = books_books(:got)
    older = Review.create!(user: users(:regular_user), reviewable: book, rating: 3,
      created_at: 2.days.ago)
    newer = Review.create!(user: users(:admin_user), reviewable: book, rating: 4,
      created_at: 1.hour.ago)

    assert_equal [newer.id, older.id], Review.where(reviewable: book).recent.pluck(:id)
  end

  test "the database rejects an empty-string body" do
    review = reviews(:admin_user_war_and_peace)
    assert_raises(ActiveRecord::StatementInvalid) do
      Review.where(id: review.id).update_all(body: "")
    end
  end

  test "the database rejects a whitespace-only body" do
    review = reviews(:admin_user_war_and_peace)
    assert_raises(ActiveRecord::StatementInvalid) do
      Review.where(id: review.id).update_all(body: "\t\n")
    end
  end

  test "the database rejects an out-of-range rating" do
    review = reviews(:admin_user_war_and_peace)
    assert_raises(ActiveRecord::StatementInvalid) do
      Review.where(id: review.id).update_all(rating: 9)
    end
  end

  test "creating a review refreshes the summary" do
    book = books_books(:got)
    Review.create!(user: users(:regular_user), reviewable: book, rating: 5)

    summary = ReviewSummary.find_by(reviewable_type: "Books::Book", reviewable_id: book.id)
    assert_equal 1, summary.ratings_count
    assert_equal 5, summary.ratings_sum
  end

  test "destroying a review refreshes the summary" do
    review = reviews(:admin_user_war_and_peace)
    book = review.reviewable
    review.destroy!

    summary = ReviewSummary.find_by(reviewable_type: "Books::Book", reviewable_id: book.id)
    assert_equal 2, summary.ratings_count
    assert_equal 9, summary.ratings_sum
    assert_equal 1, summary.rating_4_count
  end

  test "updating a review's rating refreshes the summary" do
    # war_and_peace starts at 3 ratings summing to 13: one 5-star (regular_user), two
    # 4-star (editor_user, admin_user).
    review = reviews(:regular_user_war_and_peace)
    book = review.reviewable

    review.update!(rating: 2)

    summary = ReviewSummary.find_by(reviewable_type: "Books::Book", reviewable_id: book.id)
    assert_equal 3, summary.ratings_count
    assert_equal 10, summary.ratings_sum
    assert_equal 1, summary.rating_2_count
    assert_equal 2, summary.rating_4_count
    assert_equal 0, summary.rating_5_count
  end
end
