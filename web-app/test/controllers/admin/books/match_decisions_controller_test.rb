require "test_helper"

module Admin
  module Books
    class MatchDecisionsControllerTest < ActionDispatch::IntegrationTest
      setup do
        host! Rails.application.config.domains[:books]
        @admin = users(:admin_user)
        @viewer = users(:books_viewer_user)
        @regular = users(:regular_user)
        @pending = match_decisions(:low_confidence_book_match)
        @sweep = match_decisions(:war_and_peace_sweep)
        @created = match_decisions(:new_book_created)
        @reviewed = match_decisions(:reviewed_book_match)
        @music = match_decisions(:dark_side_album_match)
      end

      def row_ids
        css_select("[data-testid=decision-row]").map { |row| row["data-decision-id"].to_i }
      end

      test "index redirects unauthenticated users and regular users" do
        get admin_books_match_decisions_path
        assert_redirected_to books_root_path

        sign_in_as(@regular, stub_auth: true)
        get admin_books_match_decisions_path
        assert_redirected_to books_root_path
      end

      test "index allows a books domain viewer" do
        sign_in_as(@viewer, stub_auth: true)
        get admin_books_match_decisions_path
        assert_response :success
      end

      test "index defaults to unreviewed decisions needing review, hides verify runs, and scopes to books finders" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_match_decisions_path

        assert_response :success
        ids = row_ids
        assert_includes ids, @pending.id
        assert_includes ids, @created.id
        assert_not_includes ids, @sweep.id, "verify: true rows are hidden by default"
        assert_not_includes ids, @reviewed.id, "reviewed rows are hidden by default"
        assert_not_includes ids, @music.id, "another domain's finder never appears"
      end

      test "verify=include shows sweep rows under reviewed=all" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_match_decisions_path(verify: "include", reviewed: "all")

        assert_includes row_ids, @sweep.id
      end

      test "reviewed=reviewed shows only reviewed rows; reviewed=all shows both" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_match_decisions_path(reviewed: "reviewed")
        assert_equal [@reviewed.id], row_ids

        get admin_books_match_decisions_path(reviewed: "all")
        assert_includes row_ids, @reviewed.id
        assert_includes row_ids, @pending.id
      end

      test "outcome, confidence and decided_by filters narrow the rows" do
        sign_in_as(@admin, stub_auth: true)

        get admin_books_match_decisions_path(outcome: "matched")
        assert_equal [@pending.id], row_ids

        get admin_books_match_decisions_path(outcome: "unmatched")
        assert_equal [@created.id], row_ids

        get admin_books_match_decisions_path(confidence: "medium", reviewed: "all")
        assert_equal [@reviewed.id], row_ids

        get admin_books_match_decisions_path(decided_by: "rule", reviewed: "all", verify: "include")
        assert_equal [@sweep.id, @reviewed.id].sort, row_ids.sort
      end

      test "an unknown filter value is ignored rather than raising" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_match_decisions_path(outcome: "nonsense", reviewed: "bogus", verify: "yes", entity: "cheese")

        assert_response :success
        assert_includes row_ids, @pending.id
      end

      test "entity filter matches the registry label" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_match_decisions_path(entity: "book")
        assert_includes row_ids, @pending.id

        get admin_books_match_decisions_path(entity: "album")
        assert_empty row_ids
      end

      test "rows carry the attributes the filters key on" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_match_decisions_path

        assert_select "[data-testid=decision-row][data-decision-id=?][data-outcome=matched][data-confidence=low][data-decided-by=ai][data-verify=false]", @pending.id.to_s
      end

      test "index accepts a page parameter" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_match_decisions_path(page: 1)
        assert_response :success
      end

      test "show renders the decision, its candidates with the selected row marked, and the shared identifier" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_match_decision_path(@pending)

        assert_response :success
        assert_select "[data-testid=candidate-row][data-candidate-index='1'][data-selected=true]"

        get admin_books_match_decision_path(@created)
        assert_select "[data-testid=candidate-row][data-selected=false]"
        assert_select "[data-testid=shared-identifiers]", text: /9780553103540/
      end

      test "show links the candidate's admin page and the record's" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_match_decision_path(@created)

        assert_select "a[href=?]", admin_books_book_path(books_books(:war_and_peace))
        assert_select "a[href=?]", admin_books_book_path(books_books(:got))
      end

      test "show renders a compare panel for a re-check" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_match_decision_path(@sweep, compare: @pending.id)

        assert_select "[data-testid=recheck-comparison]"
        assert_select "[data-testid=recheck-comparison] a[href=?]", admin_books_match_decision_path(@pending)
      end

      test "show ignores a compare id from another domain" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_match_decision_path(@sweep, compare: @music.id)

        assert_response :success
        assert_select "[data-testid=recheck-comparison]", count: 0
      end

      test "show 404s for another domain's decision" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_match_decision_path(@music)
        assert_response :not_found
      end
    end
  end
end
