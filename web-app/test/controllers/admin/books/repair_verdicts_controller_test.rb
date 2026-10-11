require "test_helper"

module Admin
  module Books
    class RepairVerdictsControllerTest < ActionDispatch::IntegrationTest
      setup do
        host! Rails.application.config.domains[:books]
        @admin = users(:admin_user)
        @viewer = users(:books_viewer_user)
        @book = books_books(:war_and_peace)
        @relink = verdict(:relink, "user:1:book:#{@book.id}:goodreads:9", decided_by: :ai, confidence: :high,
          payload: {"user_id" => 1, "from_book_id" => @book.id, "to_book_id" => books_books(:got).id, "goodreads_book_id" => 9,
                    "rows" => [[501, 3]]})
        @merge = verdict(:merge_books, "books:1:2", status: :approved, payload: {"source_id" => 2, "target_id" => 1})
      end

      def verdict(kind, key, status: :proposed, decided_by: :rule, confidence: :certain, payload: {})
        ::Books::RepairVerdict.create!(kind: kind, subject_key: key, status: status, decided_by: decided_by,
          confidence: confidence, payload: payload, reason: "test")
      end

      def verdict_ids
        css_select("[data-testid=verdict-row]").map { |row| row["data-verdict-id"].to_i }
      end

      test "index redirects unauthenticated users" do
        get admin_books_repair_verdicts_path
        assert_redirected_to books_root_path
      end

      test "index defaults to proposed verdicts and filters by kind, decider and confidence" do
        sign_in_as(@admin, stub_auth: true)

        get admin_books_repair_verdicts_path
        assert_equal [@relink.id], verdict_ids

        get admin_books_repair_verdicts_path(status: "approved")
        assert_equal [@merge.id], verdict_ids

        get admin_books_repair_verdicts_path(kind: "merge_books")
        assert_empty verdict_ids

        get admin_books_repair_verdicts_path(decided_by: "ai", confidence: "high", kind: "bogus", status: "bogus")
        assert_equal [@relink.id], verdict_ids
      end

      test "show renders the verdict with its source rows" do
        import = ::Books::GoodreadsImport.create!(user: users(:regular_user), source: :legacy_replay, status: :complete, legacy_import_id: 501)
        import.rows.create!(row_number: 3, raw: {"Title" => "War and Peace", "Author" => "Leo Tolstoy"})
        sign_in_as(@admin, stub_auth: true)

        get admin_books_repair_verdict_path(@relink)

        assert_response :success
        assert_select "[data-testid=source-row]", 1
      end

      test "approve records the reviewer and leaves the finder's decider" do
        sign_in_as(@admin, stub_auth: true)

        post approve_admin_books_repair_verdict_path(@relink)

        @relink.reload
        assert_predicate @relink, :approved?
        assert_predicate @relink, :decided_by_ai?
        assert_equal @admin.id, @relink.decided_by_user_id
        refute_nil @relink.reviewed_at
        assert_nil @relink.applied_at
      end

      test "a books viewer cannot approve or reject" do
        sign_in_as(@viewer, stub_auth: true)

        post approve_admin_books_repair_verdict_path(@relink)
        assert_redirected_to books_root_path
        post reject_admin_books_repair_verdict_path(@relink)
        assert_redirected_to books_root_path
        assert_predicate @relink.reload, :proposed?
      end

      test "reject marks a verdict rejected" do
        sign_in_as(@admin, stub_auth: true)

        post reject_admin_books_repair_verdict_path(@relink)

        assert_predicate @relink.reload, :rejected?
        assert_equal @admin.id, @relink.decided_by_user_id
      end

      test "rejecting an applied merge undoes nothing now but stops it being re-applied after a re-migration" do
        applied_at = 1.day.ago.change(usec: 0)
        @merge.update!(applied_at: applied_at)
        sign_in_as(@admin, stub_auth: true)

        post reject_admin_books_repair_verdict_path(@merge)

        assert_predicate @merge.reload, :rejected?
        assert_equal applied_at, @merge.applied_at
        assert_redirected_to admin_books_repair_verdict_path(@merge)
        assert_match(/not undone/, flash[:notice])
      end

      test "rejecting an applied mark_provisional reverts it" do
        @book.update!(provisional: true)
        flagged = verdict(:mark_provisional, "book:#{@book.id}", status: :approved, payload: {"book_id" => @book.id})
        flagged.update!(applied_at: Time.current)
        ::Services::RankingConfigurations::RequestRefresh.expects(:call_for_ids).with(anything, delay: 5.minutes).once
        sign_in_as(@admin, stub_auth: true)

        post reject_admin_books_repair_verdict_path(flagged)

        assert_predicate flagged.reload, :rejected?
        refute @book.reload.provisional
      end

      test "bulk approve approves the selected proposed verdicts only" do
        other = verdict(:relink, "user:2:book:3:goodreads:4", decided_by: :ai)
        sign_in_as(@admin, stub_auth: true)

        post bulk_approve_admin_books_repair_verdicts_path, params: {ids: [@relink.id, @merge.id]}

        assert_predicate @relink.reload, :approved?
        assert_predicate other.reload, :proposed?
        assert_equal @admin.id, @relink.decided_by_user_id
      end

      test "bulk approve of all matching approves only proposed verdicts the filter selects" do
        ai = verdict(:relink, "user:2:book:3:goodreads:4", decided_by: :ai, confidence: :low)
        sign_in_as(@admin, stub_auth: true)

        post bulk_approve_admin_books_repair_verdicts_path, params: {all_matching: "1", kind: "relink", confidence: "high"}

        assert_predicate @relink.reload, :approved?
        assert_predicate ai.reload, :proposed?
      end
    end
  end
end
