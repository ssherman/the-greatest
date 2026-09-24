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

      test "a pending pair offers both merge directions through the target's execute_action, each with a required confirm" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_duplicate_candidates_path

        a, b = [@got, @clash].sort_by(&:id)
        assert_select "[data-testid=merge-a-into-b] form[data-testid=merge-form][action=?]", execute_action_admin_books_book_path(b) do
          assert_select "input[name=action_name][value=MergeBook]"
          assert_select "input[name=source_book_id][value=?]", a.id.to_s
          assert_select "input[type=checkbox][name=confirm_merge][required]"
        end
        assert_select "[data-testid=merge-b-into-a] form[data-testid=merge-form][action=?]", execute_action_admin_books_book_path(a) do
          assert_select "input[name=source_book_id][value=?]", b.id.to_s
        end
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
