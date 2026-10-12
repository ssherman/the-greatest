require "test_helper"

module Admin
  module Books
    class DuplicateCandidatesControllerTest < ActionDispatch::IntegrationTest
      setup do
        host! Rails.application.config.domains[:books]
        @admin = users(:admin_user)
        @viewer = users(:books_viewer_user)
        @pending = duplicate_candidates(:books_pending_pair)
        @dismissed = duplicate_candidates(:books_dismissed_pair)
        @games_pair = duplicate_candidates(:resident_evil_4_pair)
        @got = books_books(:got)
        @clash = books_books(:clash)
      end

      def pair_ids
        css_select("[data-testid=pair-row]").map { |row| row["data-pair-id"].to_i }
      end

      test "index redirects unauthenticated users" do
        get admin_books_duplicate_candidates_path
        assert_redirected_to books_root_path
      end

      test "index defaults to pending books pairs only" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_duplicate_candidates_path

        assert_response :success
        assert_equal [@pending.id], pair_ids
        assert_select "[data-testid=pair-row][data-item-type='Books::Book'][data-status=pending]"
      end

      test "status filter shows dismissed pairs; an unknown status falls back to pending" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_duplicate_candidates_path(status: "not_duplicate")
        assert_equal [@dismissed.id], pair_ids

        get admin_books_duplicate_candidates_path(status: "merged")
        assert_empty pair_ids

        get admin_books_duplicate_candidates_path(status: "bogus")
        assert_equal [@pending.id], pair_ids
      end

      test "index reports counts per status for this domain" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_duplicate_candidates_path

        assert_select "[data-testid=status-count-pending]", text: DuplicateCandidate.where(item_type: "Books::Book", status: :pending).count.to_s
        assert_select "[data-testid=status-count-not_duplicate]", text: DuplicateCandidate.where(item_type: "Books::Book", status: :not_duplicate).count.to_s
      end

      test "a pair renders both records side by side with links to their admin pages" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_duplicate_candidates_path

        a, b = [@got, @clash].sort_by(&:id)
        assert_select "[data-testid=pair-side][data-side=A][data-record-id=?]", a.id.to_s do
          assert_select "a[href=?]", admin_books_book_path(a)
        end
        assert_select "[data-testid=pair-side][data-side=B][data-record-id=?]", b.id.to_s do
          assert_select "a[href=?]", admin_books_book_path(b)
        end
        assert_select "[data-testid=pair-row][data-pair-id=?] a[href=?]", @pending.id.to_s, admin_books_match_decision_path(@pending.match_decision)
      end

      test "a pending pair offers both merge directions through this page's merge endpoint, each naming the records it shows" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_duplicate_candidates_path(page: 1)

        a, b = [@got, @clash].sort_by(&:id)
        assert_select "[data-testid=merge-a-into-b] form[data-testid=merge-form][action=?]", merge_admin_books_duplicate_candidate_path(@pending) do
          assert_select "input[name=source_id][value=?]", a.id.to_s
          assert_select "input[name=target_id][value=?]", b.id.to_s
          assert_select "input[name=return_to][value=?]", admin_books_duplicate_candidates_path(page: 1)
          assert_select "input[type=checkbox][name=confirm_merge][required]"
        end
        assert_select "[data-testid=merge-b-into-a] form[data-testid=merge-form]" do
          assert_select "input[name=source_id][value=?]", b.id.to_s
          assert_select "input[name=target_id][value=?]", a.id.to_s
        end
        assert_select "form[data-testid=dismiss-form] input[name=return_to][value=?]", admin_books_duplicate_candidates_path(page: 1)
      end

      test "the index morphs on refresh and keeps the scroll position" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_duplicate_candidates_path

        assert_select "meta[name=turbo-refresh-method][content=morph]"
        assert_select "meta[name=turbo-refresh-scroll][content=preserve]"
      end

      test "a page holds up to 100 pairs" do
        sign_in_as(@admin, stub_auth: true)
        now = Time.current
        DuplicateCandidate.insert_all((1..100).map { |i|
          {item_type: "Books::Book", item_a_id: 900_000_000 + i, item_b_id: 950_000_000 + i, source: 4, status: 0, evidence: {}, created_at: now, updated_at: now}
        })

        get admin_books_duplicate_candidates_path
        assert_equal 100, pair_ids.size

        get admin_books_duplicate_candidates_path(page: 2)
        assert_equal 1, pair_ids.size
      end

      test "a page past the end redirects to the last page, keeping the status" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_duplicate_candidates_path(status: "pending", page: 3)

        assert_redirected_to admin_books_duplicate_candidates_path(status: "pending", page: 1)
      end

      # ---- merge ----------------------------------------------------------------

      def post_merge(pair, source:, target:, confirm: "1", return_to: admin_books_duplicate_candidates_path(page: 1))
        post merge_admin_books_duplicate_candidate_path(pair),
          params: {source_id: source.id, target_id: target.id, confirm_merge: confirm, return_to: return_to}.compact
      end

      test "merge A into B deletes A, marks the pair merged and returns to the page it came from" do
        GenerateUserFavoritesListsJob.stubs(:perform_async)
        sign_in_as(@admin, stub_auth: true)
        a, b = [@got, @clash].sort_by(&:id)

        post_merge(@pending, source: a, target: b)

        assert_redirected_to admin_books_duplicate_candidates_path(page: 1)
        assert_match "Successfully merged", flash[:notice]
        assert_not ::Books::Book.exists?(a.id)
        assert ::Books::Book.exists?(b.id)
        assert @pending.reload.merged?
      end

      test "merge B into A deletes B" do
        GenerateUserFavoritesListsJob.stubs(:perform_async)
        sign_in_as(@admin, stub_auth: true)
        a, b = [@got, @clash].sort_by(&:id)

        post_merge(@pending, source: b, target: a)

        assert_not ::Books::Book.exists?(b.id)
        assert ::Books::Book.exists?(a.id)
      end

      # The delete gate execute_action enforces for a destructive action; a
      # merge here must not be a way around it.
      test "a books domain editor cannot merge" do
        GenerateUserFavoritesListsJob.stubs(:perform_async)
        editor = users(:regular_user)
        editor.domain_roles.create!(domain: :books, permission_level: :editor)
        sign_in_as(editor, stub_auth: true)

        post_merge(@pending, source: @got, target: @clash)

        assert_match "not authorized", flash[:alert]
        assert ::Books::Book.exists?(@got.id), "an editor must not be able to delete via merge"
        assert @pending.reload.pending?
      end

      test "a viewer cannot merge" do
        sign_in_as(@viewer, stub_auth: true)
        post_merge(@pending, source: @got, target: @clash)

        assert_redirected_to books_root_path
        assert ::Books::Book.exists?(@got.id)
      end

      test "merge of a resolved pair merges nothing" do
        sign_in_as(@admin, stub_auth: true)
        @pending.update!(status: :not_duplicate)

        post_merge(@pending, source: @got, target: @clash)

        assert_redirected_to admin_books_duplicate_candidates_path(page: 1)
        assert_match "already", flash[:alert]
        assert ::Books::Book.exists?(@got.id)
        assert ::Books::Book.exists?(@clash.id)
      end

      # A merge elsewhere re-keys pending pairs onto its survivor in place, so
      # by the time a form posts, its pair can name a record it never showed.
      test "merge refuses when the pair no longer names the records the form showed" do
        sign_in_as(@admin, stub_auth: true)
        other = books_books(:war_and_peace)
        a, b = [@clash.id, other.id].minmax
        @pending.update!(item_a_id: a, item_b_id: b)

        post_merge(@pending, source: @got, target: @clash)

        assert_redirected_to admin_books_duplicate_candidates_path(page: 1)
        assert_match "changed", flash[:alert]
        assert ::Books::Book.exists?(@got.id)
        assert ::Books::Book.exists?(other.id)
        assert ::Books::Book.exists?(@clash.id)
      end

      test "merge refuses when one of the records no longer exists" do
        sign_in_as(@admin, stub_auth: true)
        ghost = DuplicateCandidate.create!(item_type: "Books::Book", item_a_id: @got.id, item_b_id: 999_999_999, source: :ai, status: :pending, evidence: {})

        post merge_admin_books_duplicate_candidate_path(ghost), params: {source_id: 999_999_999, target_id: @got.id, confirm_merge: "1"}

        assert_redirected_to admin_books_duplicate_candidates_path
        assert_match "no longer exists", flash[:alert]
        assert ghost.reload.pending?
      end

      test "merge without the confirm box reports the action's error and merges nothing" do
        sign_in_as(@admin, stub_auth: true)

        post_merge(@pending, source: @got, target: @clash, confirm: nil)

        assert_match "confirm", flash[:alert]
        assert ::Books::Book.exists?(@got.id)
        assert @pending.reload.pending?
      end

      test "merge ignores a return_to that is not this index" do
        sign_in_as(@admin, stub_auth: true)
        @pending.update!(status: :not_duplicate)

        post_merge(@pending, source: @got, target: @clash, return_to: "https://evil.example/admin/duplicate_candidates")
        assert_redirected_to admin_books_duplicate_candidates_path(status: "not_duplicate")

        post_merge(@pending, source: @got, target: @clash, return_to: admin_books_books_path)
        assert_redirected_to admin_books_duplicate_candidates_path(status: "not_duplicate")
      end

      test "merge of another domain's pair 404s" do
        sign_in_as(@admin, stub_auth: true)
        post merge_admin_books_duplicate_candidate_path(@games_pair), params: {source_id: 1, target_id: 2, confirm_merge: "1"}
        assert_response :not_found
      end

      test "a dismissed pair offers no actions" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_duplicate_candidates_path(status: "not_duplicate")

        assert_select "[data-testid=pair-actions]", count: 0
        assert_select "form[data-testid=merge-form]", count: 0
      end

      test "a viewer sees pairs but no actions and cannot dismiss" do
        sign_in_as(@viewer, stub_auth: true)
        get admin_books_duplicate_candidates_path
        assert_response :success
        assert_select "[data-testid=pair-actions]", count: 0

        post dismiss_admin_books_duplicate_candidate_path(@pending), params: {resolution_note: "nope"}
        assert_redirected_to books_root_path
        assert @pending.reload.pending?
      end

      test "a pair whose record no longer exists says so and offers dismissal only" do
        sign_in_as(@admin, stub_auth: true)
        ghost = DuplicateCandidate.create!(item_type: "Books::Book", item_a_id: @got.id, item_b_id: 999_999_999, source: :ai, status: :pending, evidence: {})

        get admin_books_duplicate_candidates_path

        assert_select "[data-testid=pair-row][data-pair-id=?]", ghost.id.to_s do
          assert_select "[data-testid=pair-side][data-record-id='999999999'][data-missing=true]"
          assert_select "form[data-testid=dismiss-form]"
          assert_select "form[data-testid=merge-form]", count: 0
        end
      end

      test "dismiss marks the pair not a duplicate with the note and resolver" do
        sign_in_as(@admin, stub_auth: true)
        post dismiss_admin_books_duplicate_candidate_path(@pending), params: {resolution_note: "Different novels."}

        assert_redirected_to admin_books_duplicate_candidates_path
        @pending.reload
        assert @pending.not_duplicate?
        assert_equal @admin, @pending.resolved_by
        assert_equal "Different novels.", @pending.resolution_note
        assert_not_nil @pending.resolved_at
      end

      test "dismiss returns to the page it came from" do
        sign_in_as(@admin, stub_auth: true)
        post dismiss_admin_books_duplicate_candidate_path(@pending), params: {return_to: admin_books_duplicate_candidates_path(page: 2)}

        assert_redirected_to admin_books_duplicate_candidates_path(page: 2)
        assert @pending.reload.not_duplicate?
      end

      test "dismiss of a resolved pair changes nothing" do
        sign_in_as(@admin, stub_auth: true)
        before = [@dismissed.status, @dismissed.resolution_note, @dismissed.resolved_at]

        post dismiss_admin_books_duplicate_candidate_path(@dismissed), params: {resolution_note: "again"}

        assert_redirected_to admin_books_duplicate_candidates_path(status: "not_duplicate")
        assert_equal before, [@dismissed.reload.status, @dismissed.resolution_note, @dismissed.resolved_at]
      end

      test "dismiss of another domain's pair 404s" do
        sign_in_as(@admin, stub_auth: true)
        post dismiss_admin_books_duplicate_candidate_path(@games_pair)
        assert_response :not_found
      end

      test "a dismissed pair is never re-raised by the finder's never-merge check" do
        sign_in_as(@admin, stub_auth: true)
        post dismiss_admin_books_duplicate_candidate_path(@pending)

        assert DuplicateCandidate.not_duplicate?(item_type: "Books::Book", ids: [@clash.id, @got.id])
      end
    end
  end
end
