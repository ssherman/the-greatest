require "test_helper"

module Services
  module Books
    module BookSubmissions
      class SupplyDetailsTest < ActiveSupport::TestCase
        include BookSubmissionReviewHelper

        setup do
          ::Books::ProcessBookSubmissionJob.stubs(:perform_async)
          @admin = users(:admin_user)
          @submission = lease(reviewable_submission(book: nil, status: :needs_details, review_status: :not_needed, attempts: 3,
            blocked_fetches: 1, sweeps: 2, fetch_errors: 1, claims: 2, error: "old", next_attempt_at: 1.hour.ago, processing_started_at: 2.hours.ago))
        end

        def supply(submission = @submission, via: "api", lease_token: TOKEN, title: "The Quiet Year", author_names: ["Anna Brenner"],
          identifiers: {}, note: "Found on the publisher's page")
          SupplyDetails.call(submission: submission, title: title, author_names: author_names, identifiers: identifiers,
            user: @admin, via: via, lease_token: lease_token, note: note)
        end

        test "stores the details, resets the row to queued and queues the job" do
          ::Books::ProcessBookSubmissionJob.expects(:perform_async).with(@submission.id).once

          result = supply(identifiers: {isbn13: "978-0-14-044793-4", goodreads_id: "656.War_and_Peace", asin: "b00abc1234"})

          assert_success result
          row = fresh(@submission)
          assert_equal({"title" => "The Quiet Year", "author_names" => ["Anna Brenner"],
            "identifiers" => {"isbn13" => ["9780140447934"], "isbn10" => ["0140447938"], "asin" => ["B00ABC1234"], "goodreads_id" => ["656"]}}, row.supplied)
          assert_equal ["queued", nil, 0, 0, 0, 0, 0, nil, nil, nil, nil, "Found on the publisher's page"],
            [row.status, row.error, row.attempts, row.blocked_fetches, row.sweeps, row.fetch_errors, row.claims,
              row.next_attempt_at, row.processing_started_at, row.lease_token, row.lease_expires_at, row.review_note]
        end

        test "works from failed, and a pending review stays pending" do
          row = lease(reviewable_submission(book: nil, status: :failed, review_status: :pending))

          assert_success supply(row)
          assert_equal ["queued", "pending"], [fresh(row).status, fresh(row).review_status]
        end

        test "refused once a book exists, for a rejected row, and for a row not needing details" do
          with_book = lease(reviewable_submission(status: :needs_details, review_status: :not_needed))
          assert_failure supply(with_book), :conflict, "book"
          rejected = lease(reviewable_submission(book: nil, status: :failed, review_status: :rejected))
          assert_failure supply(rejected), :conflict
          looking = lease(reviewable_submission(book: nil, status: :looking_up, review_status: :not_needed))
          assert_failure supply(looking), :conflict
          assert_equal "needs_details", fresh(@submission).status
        end

        test "the API needs a live matching lease, judged before input; the admin page needs none" do
          assert_failure supply(lease_token: "x", title: ""), :conflict
          assert_failure supply(lease_token: nil), :conflict
          @submission.update_columns(lease_expires_at: 1.minute.ago)
          assert_failure supply, :conflict
          assert_success supply(via: "admin_ui", lease_token: nil)
        end

        test "title and authors obey the limits of a reader's form" do
          assert_failure supply(title: ""), :invalid, "title"
          assert_failure supply(title: "x" * 256), :invalid, "title"
          assert_failure supply(title: nil), :invalid, "title"
          assert_failure supply(author_names: []), :invalid, "author"
          assert_failure supply(author_names: Array.new(11) { "Author #{it}" }), :invalid, "author"
          assert_failure supply(author_names: ["x" * 256]), :invalid, "author"
          assert_failure supply(author_names: [" "]), :invalid, "author"
          assert_failure supply(author_names: "Anna Brenner"), :invalid, "author"
          assert_success supply(title: "x" * 255, author_names: Array.new(10) { "A" * 255 })
        end

        test "title and names are scrubbed and squished" do
          supply(title: "  The \u0000 Quiet   Year ", author_names: ["Anna  Brenner "])

          assert_equal ["The Quiet Year", ["Anna Brenner"]], fresh(@submission).supplied.values_at("title", "author_names")
        end

        test "identifiers are validated, never stored raw" do
          assert_failure supply(identifiers: {isbn13: "9780140447935"}), :invalid, "isbn13"
          assert_failure supply(identifiers: {asin: "not-an-asin"}), :invalid, "asin"
          assert_failure supply(identifiers: {goodreads_id: "abc"}), :invalid, "goodreads_id"
          assert_failure supply(identifiers: {goodreads_id: "1" * 19}), :invalid, "goodreads_id"
          assert_failure supply(identifiers: {upc: "123"}), :invalid, "upc"
          assert_failure supply(identifiers: "9780140447934"), :invalid, "identifiers"
          assert_failure supply(identifiers: {isbn13: ["9780140447934"] * 11}), :invalid, "isbn13"
          assert_nil fresh(@submission).supplied
          assert_equal "needs_details", fresh(@submission).status
        end

        test "an isbn10 given as isbn13 is stored under both forms and duplicates collapse" do
          supply(identifiers: {isbn10: ["0140447938", "0-14-044793-8"], isbn13: nil})

          assert_equal({"isbn13" => ["9780140447934"], "isbn10" => ["0140447938"], "asin" => [], "goodreads_id" => []},
            fresh(@submission).supplied["identifiers"])
        end

        test "note is 1 to 1,000 characters" do
          assert_failure supply(note: ""), :invalid, "note"
          assert_failure supply(note: "x" * 1_001), :invalid, "note"
        end

        test "a job that cannot be queued does not undo the reset" do
          ::Books::ProcessBookSubmissionJob.stubs(:perform_async).raises(RuntimeError, "redis is down")

          assert_success supply
          assert_equal "queued", fresh(@submission).status
        end

        test "a stale copy cannot supply details twice" do
          stale = ::Books::BookSubmission.find(@submission.id)
          assert_success supply

          assert_failure supply(stale, via: "admin_ui", lease_token: nil), :conflict
        end

        test "a dry-run-free call leaves a closed row's lease alone when refused" do
          assert_failure supply(title: ""), :invalid
          assert_equal TOKEN, fresh(@submission).lease_token
        end
      end
    end
  end
end
