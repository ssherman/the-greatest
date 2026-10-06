require "test_helper"

module Admin
  module Books
    class GoodreadsImportsControllerTest < ActionDispatch::IntegrationTest
      include GoodreadsImportHelper

      setup do
        host! Rails.application.config.domains[:books]
        @admin = users(:admin_user)
        @viewer = users(:books_viewer_user)
        @member = User.create!(email: "admin-import@example.com", role: :user, email_verified: false)
        @import = @member.goodreads_imports.create!(status: :complete)
        @book = ::Books::Book.create!(title: "Admin Import Book", provisional: true)
        @import.records.create!(record: @book, action: :created)
        ::Books::EnrichBookJob.stubs(:perform_async)
        ::Books::Authors::WikidataJob.stubs(:perform_async)
        ::Books::ReadingGoals::PurgeCachedPagesJob.stubs(:perform_async)
      end

      def import_ids
        css_select("[data-testid=import-row]").map { |row| row["data-import-id"].to_i }
      end

      test "signed-out users are redirected from every action" do
        get admin_books_goodreads_imports_path
        assert_redirected_to books_root_path
        [approve_admin_books_goodreads_import_path(@import), reject_admin_books_goodreads_import_path(@import),
          rerun_admin_books_goodreads_import_path(@import), promote_record_admin_books_goodreads_import_path(@import),
          delete_record_admin_books_goodreads_import_path(@import), bulk_approve_admin_books_goodreads_imports_path].each do |path|
          post path
          assert_redirected_to books_root_path
        end
      end

      test "a read-only viewer cannot approve, reject, rerun or change records" do
        sign_in_as(@viewer, stub_auth: true)

        post approve_admin_books_goodreads_import_path(@import)
        post reject_admin_books_goodreads_import_path(@import)
        post delete_record_admin_books_goodreads_import_path(@import), params: {record_type: "Books::Book", record_id: @book.id}

        assert @import.reload.review_pending?
        assert ::Books::Book.exists?(@book.id)
      end

      test "index defaults to member imports and filters by status and review status" do
        replay = @member.goodreads_imports.create!(status: :complete, source: :legacy_replay, legacy_import_id: 9101)
        sign_in_as(@admin, stub_auth: true)

        get admin_books_goodreads_imports_path
        assert_includes import_ids, @import.id
        assert_not_includes import_ids, replay.id

        get admin_books_goodreads_imports_path(source: "legacy_replay")
        assert_equal [replay.id], import_ids

        get admin_books_goodreads_imports_path(review_status: "approved")
        assert_not_includes import_ids, @import.id
      end

      test "show renders every tab" do
        edition = goodreads_edition(title: "Admin Flagged Book", book: @book, resolution: :created, resolved_at: Time.current)
        decision = ::MatchDecision.create!(finder: "DataImporters::Books::Book::Finder", subject: edition, outcome: :unmatched,
          confidence: :medium, decided_by: :ai, needs_review: true, reason: "test")
        edition.update!(match_decision: decision)
        @import.rows.create!(row_number: 1, goodreads_edition: edition, outcome: :applied, raw: {"Title" => "Admin Flagged Book"})
        @import.rows.create!(row_number: 2, outcome: :parked, outcome_detail: "not found on Goodreads", raw: {"Title" => "Invented"})
        sign_in_as(@admin, stub_auth: true)

        get admin_books_goodreads_import_path(@import, tab: "created")
        assert_select "[data-testid=created-book]", 1
        get admin_books_goodreads_import_path(@import, tab: "parked")
        assert_select "[data-testid=admin-import-row]", 1

        %w[created flagged parked rows].each do |tab|
          get admin_books_goodreads_import_path(@import, tab: tab)
          assert_response :success
        end
      end

      test "approve promotes and records the reviewer" do
        sign_in_as(@admin, stub_auth: true)

        post approve_admin_books_goodreads_import_path(@import), params: {listed_book_ids: [@book.id], keep_book_ids: [@book.id]}

        assert_redirected_to admin_books_goodreads_import_path(@import)
        assert_not @book.reload.provisional?
        assert_equal @admin.id, @import.reload.reviewed_by_id
      end

      test "approve deletes a listed book that was unticked" do
        sign_in_as(@admin, stub_auth: true)

        post approve_admin_books_goodreads_import_path(@import), params: {listed_book_ids: [@book.id]}

        assert_not ::Books::Book.exists?(@book.id)
        assert @import.reload.review_approved?
      end

      test "bulk approve approves the selected imports" do
        second = User.create!(email: "admin-import-2@example.com", role: :user, email_verified: false)
          .goodreads_imports.create!(status: :complete)
        sign_in_as(@admin, stub_auth: true)

        post bulk_approve_admin_books_goodreads_imports_path, params: {ids: [@import.id, second.id]}

        assert_equal [true, true], [@import.reload.review_approved?, second.reload.review_approved?]
      end

      test "reject reverts the import" do
        sign_in_as(@admin, stub_auth: true)

        post reject_admin_books_goodreads_import_path(@import)

        assert @import.reload.review_rejected?
        assert_not ::Books::Book.exists?(@book.id)
      end

      test "rerun queues a failed import" do
        @import.update!(status: :failed)
        ::Books::Goodreads::RunImportJob.expects(:perform_async).with(@import.id)
        sign_in_as(@admin, stub_auth: true)

        post rerun_admin_books_goodreads_import_path(@import)

        assert @import.reload.queued?
      end

      test "promote_record and delete_record act on one created record" do
        other = ::Books::Book.create!(title: "Admin Import Other", provisional: true)
        @import.records.create!(record: other, action: :created)
        sign_in_as(@admin, stub_auth: true)

        post promote_record_admin_books_goodreads_import_path(@import), params: {record_type: "Books::Book", record_id: @book.id}
        post delete_record_admin_books_goodreads_import_path(@import), params: {record_type: "Books::Book", record_id: other.id}

        assert_not @book.reload.provisional?
        assert_not ::Books::Book.exists?(other.id)
      end

      test "a record outside the import's provenance cannot be promoted or deleted through it" do
        stranger = ::Books::Book.create!(title: "Admin Import Stranger", provisional: true)
        sign_in_as(@admin, stub_auth: true)

        post delete_record_admin_books_goodreads_import_path(@import), params: {record_type: "Books::Book", record_id: stranger.id}

        assert_response :not_found
        assert ::Books::Book.exists?(stranger.id)
      end
    end
  end
end
