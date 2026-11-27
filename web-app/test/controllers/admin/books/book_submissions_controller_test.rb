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

      # Where every action lands: that one submission, with the way back to the tab and page.
      def landing(row, **query) = admin_books_book_submissions_path(submission_id: row.id, **query)

      # Follows the redirect and asserts the page shows exactly that row, as it now is.
      def assert_lands_on(row, tab: "needs_review", page: nil)
        assert_redirected_to landing(row, tab: tab, **{page: page}.compact)
        follow_redirect!
        assert_response :success
        assert_select "#submission-#{row.id}"
        assert_select "[data-submission-id]", count: 1
        assert_select "[data-testid=no-submissions]", count: 0
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
        assert_redirected_to landing(row, tab: "needs_review")
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

      test "an admin request with a target list renders on the queue" do
        admin_row = reviewable_submission(user: @admin, user_list: nil, origin: :admin, list: lists(:books_list), list_position: 4)
        sign_in_as(@admin, stub_auth: true)
        get admin_books_book_submissions_path(submission_id: admin_row.id)

        assert_response :success
        assert_select "#submission-#{admin_row.id}"
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

        assert_lands_on(@row)
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

        assert_redirected_to admin_books_book_submissions_path(submission_id: "0", tab: "needs_review")
        follow_redirect!
        assert_select "[data-testid=no-submissions]"
        assert_select "[data-testid=submission-tabs]"
        assert flash[:alert].present?
      end

      test "the tab the admin was on is kept, and a tab that is not one is not" do
        sign_in_as(@admin, stub_auth: true)
        post_action(:approve, note: "ok", tab: "all")
        assert_redirected_to landing(@row, tab: "all")

        other = reviewable_submission(user: @reader)
        post_action(:approve, other, note: "ok", tab: "//evil.example")
        assert_redirected_to landing(other, tab: "needs_review")
      end

      # Merge

      test "merge previews with a dry run and changes nothing" do
        sign_in_as(@admin, stub_auth: true)
        post_action(:merge, note: "same book", target_id: @target.id, dry_run: "true")

        assert_response :unprocessable_entity
        assert_match(/Reader Title/, notice_text)
        assert_match(/The Catalog Copy/, notice_text)
        assert ::Books::Book.exists?(@row.book_id)
        assert_equal "pending", fresh(@row).review_status
      end

      test "merge moves the submission to the target as the admin through the admin page" do
        source_id = @row.book_id
        sign_in_as(@admin, stub_auth: true)
        post_action(:merge, note: "same book", target_id: @target.id, dry_run: "false")

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

        post_action(:merge, note: "n", target_id: @target.id, dry_run: "false")

        assert_equal baseline, seen
      end

      test "merge into a provisional or missing book is an alert" do
        provisional = ::Books::Book.create!(title: "Also Provisional", provisional: true)
        sign_in_as(@admin, stub_auth: true)

        post_action(:merge, note: "n", target_id: provisional.id, dry_run: "false")
        assert_match(/provisional/, flash[:alert])
        post_action(:merge, note: "n", target_id: "", dry_run: "false")
        assert flash[:alert].present?
        assert_equal "pending", fresh(@row).review_status
      end

      # Reject

      test "reject previews with a dry run and deletes nothing" do
        sign_in_as(@admin, stub_auth: true)
        post_action(:reject, note: "no such book", dry_run: "true")

        assert_response :unprocessable_entity
        assert_match(/Reader Title/, notice_text)
        assert ::Books::Book.exists?(@row.book_id)
        assert_equal "pending", fresh(@row).review_status
      end

      test "reject deletes the provisional book and moves the row to rejected" do
        book_id = @row.book_id
        sign_in_as(@admin, stub_auth: true)
        post_action(:reject, note: "not a real book", dry_run: "false")

        assert_response :redirect
        row = fresh(@row)
        assert_equal ["rejected", @admin.id, "admin_ui", nil], [row.review_status, row.reviewed_by_id, row.reviewed_via, row.book_id]
        assert_not ::Books::Book.exists?(book_id)
      end

      test "reject of a book a curated list uses is an alert and keeps the book" do
        list = lists(:books_list)
        list.list_items.create!(listable: @row.book, position: 1)
        sign_in_as(@admin, stub_auth: true)
        post_action(:reject, note: "n", dry_run: "false")

        assert flash[:alert].present?
        assert ::Books::Book.exists?(@row.book_id)
      end

      # Only an explicit "false" is real

      test "a missing or odd dry_run is a preview, never the real merge or reject" do
        sign_in_as(@admin, stub_auth: true)

        [{}, {dry_run: ""}, {dry_run: "0"}, {dry_run: "no"}, {"dry_run" => {"a" => "1"}}, {"dry_run" => ["false"]}].each do |extra|
          post merge_admin_books_book_submission_path(@row), params: {note: "n", target_id: @target.id}.merge(extra)
          post reject_admin_books_book_submission_path(@row), params: {note: "n"}.merge(extra)
        end

        assert ::Books::Book.exists?(@row.book_id)
        assert_equal "pending", fresh(@row).review_status
      end

      test "an id that is not all digits reaches no row" do
        sign_in_as(@admin, stub_auth: true)
        post "/admin/book_submissions/#{@row.id}abc/approve", params: {note: "n"}

        assert_response :not_found
        assert_equal "pending", fresh(@row).review_status
      end

      # Merge preview and confirm

      test "the preview names both books by title, authors, year and id, and keeps the target, note and sources" do
        twin_a = ::Books::Book.create!(title: "War", first_published_year: 1999)
        twin_b = ::Books::Book.create!(title: "War", first_published_year: 2010)
        author = ::Books::Author.create!(name: "Twin Author")
        ::Books::BookAuthor.create!(book: twin_b, author: author, position: 1)
        sign_in_as(@admin, stub_auth: true)

        post_action(:merge, note: "same", sources: "https://example.com/a", target_id: twin_b.id, dry_run: "true", tab: "all")

        assert_response :unprocessable_entity
        assert_match(/"War" by Twin Author \(2010, ##{twin_b.id}\)/, notice_text)
        assert_no_match(/##{twin_a.id}\)/, notice_text)
        assert_match(/"Reader Title" by Reviewable Author \d+ \(##{@row.book_id}\)/, notice_text)
        assert_select "#submission-#{@row.id} [data-testid=merge-target-label]", text: /#{twin_b.id}/
        assert_select "#submission-#{@row.id} input[name=target_id][value='#{twin_b.id}']"
        assert_equal "same", field("note")
        assert_equal "https://example.com/a", field("sources")
      end

      test "the real merge button exists only after a preview and its confirm names both books" do
        target = ::Books::Book.create!(title: "Tom & Jerry's \"Guide\"", first_published_year: 1950)
        sign_in_as(@admin, stub_auth: true)

        get admin_books_book_submissions_path
        assert_select "#submission-#{@row.id} [data-testid=merge-preview]"
        assert_select "#submission-#{@row.id} [data-testid=merge-confirm]", count: 0

        post_action(:merge, note: "x", target_id: target.id, dry_run: "true")
        confirm = css_select("#submission-#{@row.id} [data-testid=merge-confirm]").first["data-turbo-confirm"]
        assert_includes confirm, "\"Tom & Jerry's \"Guide\"\" by unknown author (1950, ##{target.id})"
        assert_includes confirm, "Reader Title"
      end

      test "a preview naming a provisional target is refused with an alert and shows no target" do
        provisional = ::Books::Book.create!(title: "Provisional Twin", provisional: true)
        sign_in_as(@admin, stub_auth: true)
        post_action(:merge, note: "n", target_id: provisional.id, dry_run: "true")

        assert_response :redirect
        assert_match(/provisional/, flash[:alert])
      end

      # Where the admin comes back to

      def many_rows(count)
        count.times { reviewable_submission(user: @reader) }
      end

      test "a row on page two can be previewed and merged, and the admin returns to page two" do
        many_rows(52)
        last = reviewable_submission(user: @reader, title: "The Last Row")
        sign_in_as(@admin, stub_auth: true)

        get admin_books_book_submissions_path(page: 2)
        assert_select "#submission-#{last.id} [data-testid=merge-preview]"
        assert_select "#submission-#{@row.id}", count: 0
        %w[approve merge reject].each do |action|
          assert_select "#submission-#{last.id} details[data-action-name=#{action}] input[name=page][value='2']"
          assert_select "#submission-#{last.id} details[data-action-name=#{action}] input[name=tab][value=needs_review]"
        end

        post_action(:merge, last, note: "same", target_id: @target.id, dry_run: "true", tab: "needs_review", page: "2")
        assert_response :unprocessable_entity
        assert_select "#submission-#{last.id} [data-testid=merge-confirm]"
        assert_select "[data-testid=back-to-queue][href=?]", admin_books_book_submissions_path(tab: "needs_review", page: 2)

        post_action(:merge, last, note: "same", target_id: @target.id, dry_run: "false", tab: "needs_review", page: "2")
        assert_lands_on(last, page: 2)
        assert_equal "merged", fresh(last).review_status
        assert_select "[data-testid=back-to-queue][href=?]", admin_books_book_submissions_path(tab: "needs_review", page: 2)
      end

      test "a row reached through the book filter can be previewed and merged, and the admin lands on it" do
        many_rows(55)
        sign_in_as(@admin, stub_auth: true)
        book_id = @row.book_id

        get admin_books_book_submissions_path(tab: "all", book_id: book_id)
        assert_select "#submission-#{@row.id} [data-testid=merge-preview]"
        assert_select "[data-submission-id]", count: 1

        post_action(:merge, note: "same", target_id: @target.id, dry_run: "true", tab: "all", book_id: book_id)
        assert_response :unprocessable_entity
        assert_select "#submission-#{@row.id} [data-testid=merge-confirm]"
        assert_select "[data-testid=back-to-queue][href=?]", admin_books_book_submissions_path(tab: "all")

        post_action(:merge, note: "same", target_id: @target.id, dry_run: "false", tab: "all", book_id: book_id)
        assert_lands_on(@row, tab: "all")
        assert_select "[data-testid=book-filter]", count: 0
      end

      test "a reject preview is answered in place with the form filled and the way back kept" do
        many_rows(52)
        last = reviewable_submission(user: @reader, title: "The Last Row")
        sign_in_as(@admin, stub_auth: true)

        post_action(:reject, last, note: "not a book", sources: "https://example.com/s", dry_run: "true", tab: "needs_review", page: "2")

        assert_response :unprocessable_entity
        assert_match(/Dry run: would delete/, notice_text)
        assert_select "#submission-#{last.id} [data-testid=reject-confirm]"
        assert_equal "not a book", field("note", "reject")
        assert_equal "https://example.com/s", field("sources", "reject")
        assert_select "[data-testid=back-to-queue][href=?]", admin_books_book_submissions_path(tab: "needs_review", page: 2)
        assert ::Books::Book.exists?(last.book_id)
      end

      test "every action lands on its submission with the way back kept, and drops what is not digits" do
        sign_in_as(@admin, stub_auth: true)
        post_action(:approve, note: "ok", tab: "all", page: "3", book_id: @row.book_id.to_s)
        assert_redirected_to landing(@row, tab: "all", page: 3)

        other = reviewable_submission(user: @reader)
        post_action(:approve, other, note: "ok", tab: "all", page: "3x", book_id: "7;8")
        assert_redirected_to landing(other, tab: "all")
      end

      # Landing on the submission, whatever happened to it

      test "after a reject under the book filter the admin lands on the rejected row, not an empty page" do
        many_rows(55)
        sign_in_as(@admin, stub_auth: true)
        book_id = @row.book_id

        post_action(:reject, note: "not a book", dry_run: "false", tab: "all")
        assert_lands_on(@row, tab: "all")
        assert_not ::Books::Book.exists?(book_id)
        assert_select "#submission-#{@row.id} [data-testid=submission-review]", text: "Rejected"
        assert_select "[data-testid=book-filter]", count: 0
      end

      test "after a reject from page two the admin lands on the rejected row" do
        many_rows(52)
        last = reviewable_submission(user: @reader, title: "The Last Row")
        sign_in_as(@admin, stub_auth: true)

        post_action(:reject, last, note: "not a book", dry_run: "false", tab: "needs_review", page: "2")
        assert_lands_on(last, page: 2)
        assert_select "#submission-#{last.id} [data-testid=submission-review]", text: "Rejected"
      end

      test "after supply details and retry the admin lands on the queued row, from page two and from the all tab" do
        many_rows_matching = ->(count) { count.times { stuck_row } }
        many_rows_matching.call(52)
        last = stuck_row
        failed = reviewable_submission(user: @reader, book: nil, status: :failed, review_status: :not_needed, created_book: false)
        sign_in_as(@admin, stub_auth: true)

        post_action(:supply_details, last, note: "found", title: "T", authors: "A", tab: "needs_details", page: "2")
        assert_lands_on(last, tab: "needs_details", page: 2)
        assert_select "#submission-#{last.id} [data-testid=submission-status]", text: "Queued"

        post_action(:retry, failed, tab: "all", page: "2")
        assert_lands_on(failed, tab: "all", page: 2)
        assert_select "#submission-#{failed.id} [data-testid=submission-status]", text: "Queued"
      end

      test "a refused action lands on the row with the alert" do
        sign_in_as(@admin, stub_auth: true)
        post_action(:approve, note: " ", tab: "all", page: "2")

        assert_redirected_to landing(@row, tab: "all", page: 2)
        follow_redirect!
        assert_select "#submission-#{@row.id}"
        assert_select ".alert", text: /note/
      end

      test "the way back is clamped to the last page when the settled row was the only one on the last" do
        many_rows(49)
        last = reviewable_submission(user: @reader, title: "The Last Row")
        sign_in_as(@admin, stub_auth: true)

        post_action(:approve, last, note: "ok", tab: "needs_review", page: "2")
        follow_redirect!

        assert_select "[data-testid=back-to-queue][href=?]", admin_books_book_submissions_path(tab: "needs_review")
        get css_select("[data-testid=back-to-queue]").first["href"]
        assert_select "[data-submission-id]", minimum: 1
      end

      # "Pick a different book", followed from where the admin was: back on that submission, unfilled, way back kept

      test "pick a different book returns to a submission whose lookup added its book after supply details" do
        row = stuck_row
        sign_in_as(@admin, stub_auth: true)
        get admin_books_book_submissions_path(tab: "needs_details")
        submit_form(:supply_details, row, note: "found", title: "T", authors: "A")
        assert_lands_on(row, tab: "needs_details")
        row.update_columns(status: ::Books::BookSubmission.statuses[:added], book_id: ::Books::Book.create!(title: "Looked Up", provisional: true).id,
          created_book: true, review_status: ::Books::BookSubmission.review_statuses[:pending])
        get landing(row, tab: "needs_details")

        assert_pick_a_different_book_returns(row, tab: "needs_details")
        get css_select("[data-testid=back-to-queue]").first["href"]
        assert_select "#submission-#{row.id}", count: 0
      end

      test "pick a different book returns to a submission reached from the user-added badge, past page one of all" do
        many_rows(55)
        sign_in_as(@admin, stub_auth: true)
        get admin_books_book_submissions_path(tab: "all")
        assert_select "#submission-#{@row.id}", count: 0
        get admin_books_book_path(@row.book)
        get css_select("[data-testid=user-added-badge]").first["href"]

        assert_pick_a_different_book_returns(@row, tab: "all")
      end

      test "pick a different book returns to a submission opened alone whose queue row is past page one" do
        many_rows(52)
        last = reviewable_submission(user: @reader, title: "The Last Row")
        sign_in_as(@admin, stub_auth: true)
        get admin_books_book_submissions_path(tab: "needs_review")
        assert_select "#submission-#{last.id}", count: 0
        get landing(last, tab: "needs_review")

        assert_pick_a_different_book_returns(last, tab: "needs_review")
      end

      test "pick a different book from page two returns to the submission with page two as the way back" do
        many_rows(52)
        last = reviewable_submission(user: @reader, title: "The Last Row")
        sign_in_as(@admin, stub_auth: true)
        get admin_books_book_submissions_path(tab: "needs_review", page: 2)

        assert_pick_a_different_book_returns(last, tab: "needs_review", page: 2)
        get css_select("[data-testid=back-to-queue]").first["href"]
        assert_select "#submission-#{last.id}"
      end

      test "an unknown or non-digit submission id shows an empty page with the tabs, not an error" do
        sign_in_as(@admin, stub_auth: true)

        ["999999999", "abc", "#{@row.id}abc", "#{@row.id};1", ""].each do |id|
          get admin_books_book_submissions_path(submission_id: id)
          assert_response :success, id
          assert_select "[data-testid=no-submissions]"
          assert_select "[data-testid=submission-tabs]"
        end
      end

      test "the single submission banner shows only over a row, and an unknown id claims no filter either" do
        sign_in_as(@admin, stub_auth: true)
        get landing(@row)
        assert_select "[data-testid=single-submission]", count: 1
        assert_select "[data-testid=back-to-queue]", count: 1

        get admin_books_book_submissions_path(submission_id: "999999999", book_id: @row.book_id)
        assert_select "[data-testid=no-submissions]"
        assert_select "[data-testid=single-submission]", count: 0
        assert_select "[data-testid=book-filter]", count: 0

        get admin_books_book_submissions_path(tab: "approved")
        assert_select "[data-testid=no-submissions]"
        assert_select "[data-testid=back-to-queue]", count: 0
      end

      test "a submission that no longer exists still offers the way back to the page the admin was on" do
        many_rows(52)
        sign_in_as(@admin, stub_auth: true)
        post approve_admin_books_book_submission_path(id: 0), params: {note: "n", tab: "needs_review", page: "2"}
        follow_redirect!

        assert_select "[data-testid=single-submission]", count: 0
        assert_select "[data-testid=back-to-queue][href=?]", admin_books_book_submissions_path(tab: "needs_review", page: 2)
        get css_select("[data-testid=back-to-queue]").first["href"]
        assert_select "[data-submission-id]", minimum: 1
        assert_equal 2, @controller.view_assigns["pagy"].page
      end

      test "tab links carry no filter and a filter whose book is gone shows no dead link" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_book_submissions_path(tab: "all", book_id: @row.book_id)
        assert_select "[data-testid=submission-tabs] a[href*=book_id]", count: 0
        assert_select "[data-testid=book-filter] a[href=?]", admin_books_book_path(@row.book_id)

        get admin_books_book_submissions_path(tab: "all", book_id: 999_999_999)
        assert_select "[data-testid=book-filter] a.link", count: 0
        assert_select "[data-testid=book-filter]", text: /deleted/
      end

      test "after a merge preview the reject form is not filled with the merge's note and sources" do
        sign_in_as(@admin, stub_auth: true)
        post_action(:merge, note: "the merge note", sources: "https://example.com/m", target_id: @target.id, dry_run: "true")

        assert_equal "the merge note", field("note", "merge")
        assert_equal "", field("note", "reject")
        assert_equal "", field("sources", "reject")
      end

      test "a settled row's notice says which tab it moved to" do
        sign_in_as(@admin, stub_auth: true)
        post_action(:approve, note: "ok")

        assert_match(/under the Approved tab/, flash[:notice])
      end

      test "a long note and twenty long sources survive a preview and the real merge unchanged" do
        note = "漢" * 1000
        sources = Array.new(20) { |i| "https://example.com/#{"s" * 1900}#{i}" }.join("\n")
        sign_in_as(@admin, stub_auth: true)

        post_action(:merge, note: note, sources: sources, target_id: @target.id, dry_run: "true")
        assert_response :unprocessable_entity
        assert_nil response.headers["Location"]
        assert_equal note, field("note")
        assert_equal sources, field("sources")

        post_action(:merge, note: field("note"), sources: field("sources"), target_id: @target.id, dry_run: "false")
        row = fresh(@row)
        assert_equal "merged", row.review_status
        assert_equal note, row.review_note
        assert_equal 20, row.review_sources.size
      end

      test "a real merge reports each warning's detail, not the raw hash" do
        warning = {code: "book_authors_not_transferred", detail: "2 author(s) did not transfer because the surviving book already has its own."}
        ::Services::Books::AdminMerge.stubs(:call).returns(::Services::Books::AdminMerge::Result.new(success?: true, data: {warnings: [warning]}, errors: []))
        sign_in_as(@admin, stub_auth: true)
        post_action(:merge, note: "n", target_id: @target.id, dry_run: "false")

        assert_includes flash[:notice], "Warnings: 2 author(s) did not transfer because the surviving book already has its own."
        assert_no_match(/:detail|=>|\{/, flash[:notice])
      end

      test "the confirm text is escaped once" do
        @row.book.update_columns(title: "The Handmaid's Tale & Co")
        sign_in_as(@admin, stub_auth: true)
        get admin_books_book_submissions_path

        confirm = css_select("#submission-#{@row.id} [data-testid=reject-confirm]").first["data-turbo-confirm"]
        assert_equal "Permanently delete \"The Handmaid's Tale & Co\"? This cannot be undone.", confirm
      end

      # Supply details and retry

      test "supply details requeues the row with the typed details" do
        row = stuck_row
        sign_in_as(@admin, stub_auth: true)
        post_action(:supply_details, row, note: "Found on a library site", title: "  The Book  ", authors: "First Author\n\nSecond Author\n",
          isbn: "978-0-14-044793-4", asin: "", goodreads_id: "")

        assert_lands_on(row)
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

      # The dry-run notice, as rendered on the page the preview answers with.
      def notice_text = css_select(".alert").map(&:text).join(" ")

      # Posts a row's form as the page rendered it: its own action and hidden fields, plus what the admin types.
      def submit_form(action, row, **typed)
        form = css_select("#submission-#{row.id} details[data-action-name=#{action}] form").first
        hidden = form.css("input[type=hidden]").to_h { |input| [input["name"], input["value"]] }
        post form["action"], params: hidden.merge(typed.stringify_keys)
      end

      # From the page now open: previews a merge into the wrong book, follows the link, and asserts it opens
      # that submission alone, with no target picked, the autocomplete back and the way back kept.
      def assert_pick_a_different_book_returns(row, **back)
        submit_form(:merge, row, note: "same", target_id: @target.id, dry_run: "true")
        assert_response :unprocessable_entity
        link = css_select("#submission-#{row.id} [data-testid=merge-target] a").first

        get link["href"]
        assert_response :success
        assert_select "#submission-#{row.id}"
        assert_select "[data-submission-id]", count: 1
        assert_select "#submission-#{row.id} [data-testid=merge-preview]"
        assert_select "#submission-#{row.id} [data-testid=merge-target]", count: 0
        assert_select "[data-testid=back-to-queue][href=?]", admin_books_book_submissions_path(**back)
      end

      # A textarea's content as the admin sees it (the browser drops the newline right after the tag).
      def field(name, action = "merge") = css_select("details[data-action-name=#{action}] textarea[name=#{name}]").first.text.sub(/\A\n/, "")

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
