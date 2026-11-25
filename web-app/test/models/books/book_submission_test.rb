require "test_helper"

# == Schema Information
#
# Table name: books_book_submissions
#
#  id                    :bigint           not null, primary key
#  announced_at          :datetime
#  asin                  :string
#  attempts              :integer          default(0), not null
#  blocked_fetches       :integer          default(0), not null
#  created_book          :boolean          default(FALSE), not null
#  dismissed_at          :datetime
#  error                 :text
#  fetch_errors          :integer          default(0), not null
#  fingerprint           :string
#  input_method          :integer          not null
#  isbn10                :string
#  isbn13                :string
#  lease_expires_at      :datetime
#  lease_token           :string
#  lookup                :jsonb
#  next_attempt_at       :datetime
#  processing_started_at :datetime
#  raw_input             :text
#  resolved_author_names :jsonb
#  resolved_title        :string
#  review_note           :text
#  review_sources        :jsonb
#  review_status         :integer          default("not_needed"), not null
#  reviewed_at           :datetime
#  reviewed_via          :integer
#  signature             :string
#  status                :integer          default("queued"), not null
#  supplied              :jsonb
#  sweeps                :integer          default(0), not null
#  typed_author_names    :jsonb
#  typed_title           :string
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  book_id               :bigint
#  claimed_by_id         :bigint
#  goodreads_book_id     :bigint
#  match_decision_id     :bigint
#  reviewed_by_id        :bigint
#  user_id               :bigint
#  user_list_id          :bigint
#  user_list_item_id     :bigint
#
# Indexes
#
#  index_books_book_submissions_on_book_id                   (book_id)
#  index_books_book_submissions_on_claimed_by_id             (claimed_by_id)
#  index_books_book_submissions_on_match_decision_id         (match_decision_id)
#  index_books_book_submissions_on_reviewed_by_id            (reviewed_by_id)
#  index_books_book_submissions_on_signature                 (signature)
#  index_books_book_submissions_on_status_and_review_status  (status,review_status)
#  index_books_book_submissions_on_user_id_and_created_at    (user_id,created_at)
#  index_books_book_submissions_on_user_list_id              (user_list_id)
#  index_books_book_submissions_on_user_list_item_id         (user_list_item_id)
#
# Foreign Keys
#
#  fk_rails_...  (book_id => books_books.id) ON DELETE => nullify
#  fk_rails_...  (claimed_by_id => users.id) ON DELETE => nullify
#  fk_rails_...  (match_decision_id => match_decisions.id) ON DELETE => nullify
#  fk_rails_...  (reviewed_by_id => users.id) ON DELETE => nullify
#  fk_rails_...  (user_id => users.id) ON DELETE => nullify
#  fk_rails_...  (user_list_id => user_lists.id) ON DELETE => nullify
#  fk_rails_...  (user_list_item_id => user_list_items.id) ON DELETE => nullify
#
module Books
  class BookSubmissionTest < ActiveSupport::TestCase
    def build(attrs = {})
      method = attrs.fetch(:input_method, :title_authors)
      typed = (method == :title_authors) ? {typed_title: "A Title", typed_author_names: ["An Author"]} : {}
      Books::BookSubmission.new({user: users(:regular_user), input_method: method}.merge(typed).merge(attrs))
    end

    test "each method needs its own input and no other" do
      assert build.valid?

      assert_not build(input_method: :goodreads).valid?
      assert_not build(input_method: :goodreads, goodreads_book_id: 5107, typed_title: "A Title").valid?
      assert_not build(input_method: :goodreads, goodreads_book_id: 5107, typed_author_names: ["An Author"]).valid?
      assert_not build(input_method: :amazon, asin: "B000000000", typed_title: "A Title").valid?
      assert_not build(input_method: :isbn, isbn13: "9780316769488", typed_author_names: ["An Author"]).valid?
      assert_not build(raw_input: "A Title by An Author").valid?
      assert build(input_method: :goodreads, goodreads_book_id: 5107, raw_input: "https://example.com/x").valid?
      assert build(input_method: :goodreads, goodreads_book_id: 5107).valid?
      assert_not build(input_method: :goodreads, goodreads_book_id: 5107, asin: "B000000000").valid?

      assert_not build(isbn13: "9780316769488").valid?
      assert build(input_method: :amazon, asin: "0316769487", isbn10: "0316769487", isbn13: "9780316769488").valid?
      assert_not build(input_method: :amazon, asin: nil).valid?
      assert_not build(input_method: :amazon, asin: "B000000000", goodreads_book_id: 1).valid?

      assert_not build(input_method: :isbn).valid?
      assert build(input_method: :isbn, isbn10: "0316769487").valid?

      assert_not build(typed_title: " ").valid?
      assert_not build(typed_author_names: []).valid?
      assert_not build(typed_author_names: Array.new(11) { |i| "Author #{i}" }).valid?
      assert build(typed_author_names: Array.new(10) { |i| "Author #{i}" }).valid?
      assert_not build(typed_title: "x" * 256).valid?
      assert build(typed_title: "x" * 255).valid?
      assert_not build(typed_author_names: ["x" * 256]).valid?
    end

    test "reviewable keeps needs_human out however it is chained" do
      failed = books_book_submissions(:queued_goodreads)
      failed.update!(status: :failed, review_status: :needs_human)
      added = books_book_submissions(:added_title_authors)

      assert_empty Books::BookSubmission.review_needs_human.reviewable
      assert_empty Books::BookSubmission.review_needs_human.claimable
      assert_not_includes Books::BookSubmission.where(user: failed.user).reviewable, failed
      assert_not_includes Books::BookSubmission.reviewable.where(user: failed.user), failed
      assert_not_includes Books::BookSubmission.where.not(review_status: :approved).reviewable, failed

      [:approved, :not_needed].each do |review_status|
        added.update!(review_status: review_status)
        assert_not_includes Books::BookSubmission.reviewable, added
      end
    end

    test "reviewable leaves out needs_human and cancelled" do
      added = books_book_submissions(:added_title_authors)
      assert_includes Books::BookSubmission.reviewable, added

      added.update!(review_status: :needs_human)
      assert_not_includes Books::BookSubmission.reviewable, added

      added.update!(review_status: :pending, status: :cancelled)
      assert_not_includes Books::BookSubmission.reviewable, added

      added.update!(status: :failed)
      assert_includes Books::BookSubmission.reviewable, added
      added.update!(status: :needs_details, review_status: :needs_human)
      assert_not_includes Books::BookSubmission.reviewable, added

      queued = books_book_submissions(:queued_goodreads)
      assert_not_includes Books::BookSubmission.reviewable, queued
    end

    test "claimable leaves out a live lease and takes an expired one" do
      added = books_book_submissions(:added_title_authors)
      assert_includes Books::BookSubmission.claimable, added

      added.update!(lease_token: "abc", lease_expires_at: 5.minutes.from_now)
      assert_not_includes Books::BookSubmission.claimable, added

      added.update!(lease_expires_at: 1.minute.ago)
      assert_includes Books::BookSubmission.claimable, added
    end

    test "open, visible and in_progress follow status and dismissal" do
      queued = books_book_submissions(:queued_goodreads)
      added = books_book_submissions(:added_title_authors)
      assert_includes Books::BookSubmission.open, queued
      assert_not_includes Books::BookSubmission.open, added
      assert queued.in_progress?
      assert_not added.in_progress?

      queued.update!(status: :needs_details)
      assert_includes Books::BookSubmission.open, queued
      assert_not queued.in_progress?

      added.update!(dismissed_at: Time.current)
      assert_not_includes Books::BookSubmission.visible, added
      assert_includes Books::BookSubmission.visible, queued
    end

    test "label prefers the resolved title, then the typed title, then the raw input" do
      submission = build(raw_input: "raw", resolved_title: "Resolved")
      assert_equal "Resolved", submission.label
      submission.resolved_title = nil
      assert_equal "A Title", submission.label
      submission.typed_title = nil
      assert_equal "raw", submission.label
    end

    test "user_added? is true only for a created book not merged or rejected" do
      submission = books_book_submissions(:added_title_authors)
      assert submission.user_added?

      submission.review_status = :approved
      assert submission.user_added?
      submission.review_status = :merged
      assert_not submission.user_added?
      submission.review_status = :rejected
      assert_not submission.user_added?

      submission.assign_attributes(review_status: :pending, created_book: false)
      assert_not submission.user_added?
    end

    test "deleting the user, list or book keeps the row with a null id" do
      user = User.create!(email: "submitter@example.com", role: :user, email_verified: false)
      list = Books::UserList.create!(user: user, name: "Wishlist", list_type: :custom)
      book = books_books(:war_and_peace)
      submission = build(user: user, user_list: list, book: book).tap(&:save!)

      list.destroy!
      assert_nil submission.reload.user_list_id
      book.destroy!
      assert_nil submission.reload.book_id
      user.destroy!
      assert_nil submission.reload.user_id
    end
  end
end
