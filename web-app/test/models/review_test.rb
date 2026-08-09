require "test_helper"

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

  test "the database rejects an out-of-range rating" do
    review = reviews(:admin_user_war_and_peace)
    assert_raises(ActiveRecord::StatementInvalid) do
      Review.where(id: review.id).update_all(rating: 9)
    end
  end
end
