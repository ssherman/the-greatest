require "test_helper"

module Admin
  module Books
    class BookSubmissionsControllerTest < ActionDispatch::IntegrationTest
      include BookSubmissionReviewHelper

      setup do
        stub_review_side_effects
        host! Rails.application.config.domains[:books]
        @admin = users(:admin_user)
        @reader = users(:regular_user)
        @viewer = users(:books_viewer_user)
        @row = reviewable_submission(user: @reader, title: "Reader Title")
        @target = ::Books::Book.create!(title: "The Catalog Copy")
      end

      teardown { Current.reset }

      def editor
        users(:contractor_user).tap { |user| user.domain_roles.create!(domain: :books, permission_level: :editor) }
      end

      def stuck_row
        reviewable_submission(user: @reader, book: nil, status: :needs_details, review_status: :not_needed, created_book: false)
      end

      def post_action(action, row = @row, **params)
        post public_send(:"#{action}_admin_books_book_submission_path", row), params: params
      end

      # Gates

      test "index redirects an anonymous visitor and a regular user" do
        get admin_books_book_submissions_path
        assert_redirected_to books_root_path

        sign_in_as(@reader, stub_auth: true)
        get admin_books_book_submissions_path
        assert_redirected_to books_root_path
      end

      test "a books viewer can read the page but not act on it" do
        sign_in_as(@viewer, stub_auth: true)
        get admin_books_book_submissions_path
        assert_response :success

        %i[approve merge reject supply_details retry].each do |action|
          post_action(action, note: "n")
          assert_redirected_to books_root_path, action
        end
        assert_equal "pending", fresh(@row).review_status
        assert ::Books::Book.exists?(@row.book_id)
      end

      test "an editor can supply details and retry but not approve, merge or reject" do
        sign_in_as(editor, stub_auth: true)

        %i[approve merge reject].each do |action|
          post_action(action, note: "n", target_id: @target.id)
          assert_redirected_to books_root_path, action
        end
        assert_equal "pending", fresh(@row).review_status
        assert ::Books::Book.exists?(@row.book_id)

        row = stuck_row
        post_action(:supply_details, row, note: "found", title: "T", authors: "A")
        assert_redirected_to admin_books_book_submissions_path(tab: "needs_review")
        assert_equal "queued", fresh(row).status
      end

      # Index

      test "index shows the needs review tab by default with counts" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_book_submissions_path

        assert_response :success
        assert_equal "needs_review", @controller.view_assigns["tab"]
        assert_equal ::Services::Books::BookSubmissions::QueueTabs.counts, @controller.view_assigns["counts"]
        assert_includes @controller.view_assigns["submissions"].map(&:id), @row.id
        assert_select "[data-testid=copy-agent-prompt]"
      end

      test "an unknown tab shows needs review" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_book_submissions_path(tab: "bogus; DROP")

        assert_response :success
        assert_equal "needs_review", @controller.view_assigns["tab"]
      end

      test "every tab renders" do
        sign_in_as(@admin, stub_auth: true)
        ::Services::Books::BookSubmissions::QueueTabs::KEYS.each do |tab|
          get admin_books_book_submissions_path(tab: tab)
          assert_response :success, tab
        end
      end

      test "the book_id filter shows only that book's submissions" do
        other = reviewable_submission(user: @reader, title: "Another")
        sign_in_as(@admin, stub_auth: true)
        get admin_books_book_submissions_path(tab: "all", book_id: @row.book_id)

        ids = @controller.view_assigns["submissions"].map(&:id)
        assert_includes ids, @row.id
        assert_not_includes ids, other.id
      end

      test "the prompt copied is the book submissions prompt" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_book_submissions_path

        assert_equal ::Services::AgentPrompts.call(domain: :books, queue: :book_submissions), @controller.view_assigns["agent_prompt"]
      end

      test "reader text is escaped and raw input is never a link target" do
        evil = "javascript:alert(1)\"><script>alert(2)</script>"
        row = reviewable_submission(user: @reader, input_method: :amazon, goodreads_book_id: nil, asin: "B000000001",
          raw_input: evil, resolved_title: "<img src=x onerror=alert(3)>")
        sign_in_as(@admin, stub_auth: true)
        get admin_books_book_submissions_path(tab: "all")

        assert_response :success
        assert_no_match(/<script>alert\(2\)/, response.body)
        assert_no_match(/<img src=x/, response.body)
        assert_select "a[href*='javascript:']", count: 0
        assert_select "a[href='https://www.amazon.com/dp/B000000001'][rel='noopener noreferrer'][target=_blank]"
        assert_select "#submission-#{row.id} .\\[overflow-wrap\\:anywhere\\]"
      end

      test "a link is built only from a well formed id" do
        row = reviewable_submission(user: @reader, input_method: :amazon, goodreads_book_id: nil, asin: "bad asin!",
          raw_input: "https://evil.example/x")
        sign_in_as(@admin, stub_auth: true)
        get admin_books_book_submissions_path(tab: "all")

        assert_select "#submission-#{row.id} a[href*='amazon.com']", count: 0
        assert_select "#submission-#{row.id} a[href*='evil.example']", count: 0
      end

      test "a goodreads submission links to the goodreads page built from its id" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_book_submissions_path

        assert_select "#submission-#{@row.id} a[href='https://www.goodreads.com/book/show/#{@row.goodreads_book_id}'][rel='noopener noreferrer']"
      end

      test "a row offers only the actions its state allows" do
        stuck = stuck_row
        sign_in_as(@admin, stub_auth: true)
        get admin_books_book_submissions_path(tab: "all")

        assert_select "#submission-#{@row.id} [data-action-name=approve]"
        assert_select "#submission-#{@row.id} [data-action-name=supply_details]", count: 0
        assert_select "#submission-#{stuck.id} [data-action-name=supply_details]"
        assert_select "#submission-#{stuck.id} [data-action-name=approve]", count: 0
      end

      test "the viewer sees no action forms" do
        sign_in_as(@viewer, stub_auth: true)
        get admin_books_book_submissions_path

        assert_select "[data-action-name]", count: 0
      end

      test "the index does not query per row" do
        sign_in_as(@admin, stub_auth: true)
        shaped = -> do
          reviewable_submission(user: users(:editor_user), match_decision: match_decisions(:war_and_peace_sweep), review_note: "seen",
            reviewed_by: @admin, reviewed_via: :admin_ui)
        end
        shaped.call
        baseline = sql_query_count { get admin_books_book_submissions_path(tab: "all") }

        4.times { shaped.call }
        grown = sql_query_count { get admin_books_book_submissions_path(tab: "all") }

        assert_equal baseline, grown, "the index N+1s: 4 extra rows cost #{grown - baseline} extra queries"
      end

      # Approve

      test "approve promotes the book and closes the row as the admin through the admin page" do
        sign_in_as(@admin, stub_auth: true)
        post_action(:approve, note: "Open Library holds it", sources: "https://openlibrary.org/works/OL1W")

        assert_redirected_to admin_books_book_submissions_path(tab: "needs_review")
        row = fresh(@row)
        assert_equal ["approved", @admin.id, "admin_ui", "Open Library holds it", ["https://openlibrary.org/works/OL1W"]],
          [row.review_status, row.reviewed_by_id, row.reviewed_via, row.review_note, row.review_sources]
        assert_not row.book.provisional?
        assert flash[:notice].present?
      end

      test "approve with no note answers with an alert and changes nothing" do
        sign_in_as(@admin, stub_auth: true)
        post_action(:approve, note: " ")

        assert_response :redirect
        assert flash[:alert].present?
        assert_equal "pending", fresh(@row).review_status
      end

      test "approving a row another reviewer settled meanwhile is an alert, not an error" do
        @row.update_columns(review_status: ::Books::BookSubmission.review_statuses[:rejected])
        sign_in_as(@admin, stub_auth: true)
        post_action(:approve, note: "late")

        assert_response :redirect
        assert_match(/rejected/, flash[:alert])
      end

      test "a submission that no longer exists is an alert" do
        sign_in_as(@admin, stub_auth: true)
        post approve_admin_books_book_submission_path(id: 0), params: {note: "n"}

        assert_redirected_to admin_books_book_submissions_path(tab: "needs_review")
        assert flash[:alert].present?
      end

      test "the tab the admin was on is kept, and a tab that is not one is not" do
        sign_in_as(@admin, stub_auth: true)
        post_action(:approve, note: "ok", tab: "all")
        assert_redirected_to admin_books_book_submissions_path(tab: "all")

        other = reviewable_submission(user: @reader)
        post_action(:approve, other, note: "ok", tab: "//evil.example")
        assert_redirected_to admin_books_book_submissions_path(tab: "needs_review")
      end

      # Merge

      test "merge previews with a dry run and changes nothing" do
        sign_in_as(@admin, stub_auth: true)
        post_action(:merge, note: "same book", target_id: @target.id, dry_run: "true")

        assert_response :redirect
        assert_match(/Reader Title/, flash[:notice])
        assert_match(/The Catalog Copy/, flash[:notice])
        assert ::Books::Book.exists?(@row.book_id)
        assert_equal "pending", fresh(@row).review_status
      end

      test "merge moves the submission to the target as the admin through the admin page" do
        source_id = @row.book_id
        sign_in_as(@admin, stub_auth: true)
        post_action(:merge, note: "same book", target_id: @target.id)

        assert_response :redirect
        row = fresh(@row)
        assert_equal ["merged", @target.id, @admin.id, "admin_ui", "same book"],
          [row.review_status, row.book_id, row.reviewed_by_id, row.reviewed_via, row.review_note]
        assert_not ::Books::Book.exists?(source_id)
      end

      test "merge runs outside any transaction of its own" do
        sign_in_as(@admin, stub_auth: true)
        baseline = ActiveRecord::Base.connection.open_transactions
        seen = nil
        ::Services::Books::BookSubmissions::Merge.stubs(:call).with { |**| seen = ActiveRecord::Base.connection.open_transactions }
          .returns(::Services::Books::BookSubmissions::Lease.failure(:conflict, "stubbed"))

        post_action(:merge, note: "n", target_id: @target.id)

        assert_equal baseline, seen
      end

      test "merge into a provisional or missing book is an alert" do
        provisional = ::Books::Book.create!(title: "Also Provisional", provisional: true)
        sign_in_as(@admin, stub_auth: true)

        post_action(:merge, note: "n", target_id: provisional.id)
        assert_match(/provisional/, flash[:alert])
        post_action(:merge, note: "n", target_id: "")
        assert flash[:alert].present?
        assert_equal "pending", fresh(@row).review_status
      end

      # Reject

      test "reject previews with a dry run and deletes nothing" do
        sign_in_as(@admin, stub_auth: true)
        post_action(:reject, note: "no such book", dry_run: "true")

        assert_response :redirect
        assert_match(/Reader Title/, flash[:notice])
        assert ::Books::Book.exists?(@row.book_id)
        assert_equal "pending", fresh(@row).review_status
      end

      test "reject deletes the provisional book and moves the row to rejected" do
        book_id = @row.book_id
        sign_in_as(@admin, stub_auth: true)
        post_action(:reject, note: "not a real book")

        assert_response :redirect
        row = fresh(@row)
        assert_equal ["rejected", @admin.id, "admin_ui", nil], [row.review_status, row.reviewed_by_id, row.reviewed_via, row.book_id]
        assert_not ::Books::Book.exists?(book_id)
      end

      test "reject of a book a curated list uses is an alert and keeps the book" do
        list = lists(:books_list)
        list.list_items.create!(listable: @row.book, position: 1)
        sign_in_as(@admin, stub_auth: true)
        post_action(:reject, note: "n")

        assert flash[:alert].present?
        assert ::Books::Book.exists?(@row.book_id)
      end

      # Supply details and retry

      test "supply details requeues the row with the typed details" do
        row = stuck_row
        sign_in_as(@admin, stub_auth: true)
        post_action(:supply_details, row, note: "Found on a library site", title: "  The Book  ", authors: "First Author\n\nSecond Author\n",
          isbn: "978-0-14-044793-4", asin: "", goodreads_id: "")

        assert_redirected_to admin_books_book_submissions_path(tab: "needs_review")
        row = fresh(row)
        assert_equal "queued", row.status
        assert_equal "The Book", row.supplied["title"]
        assert_equal ["First Author", "Second Author"], row.supplied["author_names"]
        assert_includes row.supplied["identifiers"]["isbn13"], "9780140447934"
      end

      test "supply details with a bad identifier is an alert and changes nothing" do
        row = stuck_row
        sign_in_as(@admin, stub_auth: true)
        post_action(:supply_details, row, note: "n", title: "T", authors: "A", isbn: "not an isbn")

        assert flash[:alert].present?
        assert_equal "needs_details", fresh(row).status
      end

      test "supply details on a row that already has a book is an alert" do
        sign_in_as(@admin, stub_auth: true)
        post_action(:supply_details, note: "n", title: "T", authors: "A")

        assert flash[:alert].present?
      end

      test "retry requeues a failed row and refuses one that is not failed" do
        failed = reviewable_submission(user: @reader, book: nil, status: :failed, review_status: :not_needed, created_book: false)
        sign_in_as(@admin, stub_auth: true)

        post_action(:retry, failed)
        assert_equal "queued", fresh(failed).status

        post_action(:retry, failed)
        assert flash[:alert].present?
      end

      private

      def sql_query_count
        count = 0
        subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
          count += 1 unless payload[:name].in?(["SCHEMA", "TRANSACTION"])
        end
        yield
        count
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end
    end
  end
end
