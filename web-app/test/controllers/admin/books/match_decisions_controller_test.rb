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

      # ---- review ------------------------------------------------------------

      test "review marks the decision reviewed by the current user with the note" do
        sign_in_as(@admin, stub_auth: true)
        post review_admin_books_match_decision_path(@pending), params: {review_note: "Checked by hand."}

        assert_redirected_to admin_books_match_decision_path(@pending)
        @pending.reload
        assert_equal @admin, @pending.reviewed_by
        assert_equal "Checked by hand.", @pending.review_note
        assert_not_nil @pending.reviewed_at
      end

      test "review of an already reviewed decision changes nothing" do
        sign_in_as(@admin, stub_auth: true)
        before = [@reviewed.reviewed_at, @reviewed.reviewed_by_id, @reviewed.review_note]

        post review_admin_books_match_decision_path(@reviewed), params: {review_note: "again"}

        assert_redirected_to admin_books_match_decision_path(@reviewed)
        assert_equal before, [@reviewed.reload.reviewed_at, @reviewed.reviewed_by_id, @reviewed.review_note]
      end

      test "a viewer cannot review and sees no action forms" do
        sign_in_as(@viewer, stub_auth: true)

        get admin_books_match_decision_path(@pending)
        assert_select "[data-testid=decision-actions]", count: 0

        post review_admin_books_match_decision_path(@pending), params: {review_note: "nope"}
        assert_redirected_to books_root_path
        assert_nil @pending.reload.reviewed_at
      end

      test "review of another domain's decision 404s" do
        sign_in_as(@admin, stub_auth: true)
        post review_admin_books_match_decision_path(@music)
        assert_response :not_found
      end

      # ---- recheck -----------------------------------------------------------

      test "recheck runs the finder with verify on, excluding a sweep decision's subject, and shows the new decision beside the old" do
        sign_in_as(@admin, stub_auth: true)
        book = books_books(:war_and_peace)
        new_decision = @pending
        DataImporters::Books::Book::Finder.any_instance.expects(:call).with do |args|
          args[:query].is_a?(DataImporters::Books::Book::ImportQuery) &&
            args[:query].title == "War and Peace" && args[:query].author_names == ["Leo Tolstoy"] &&
            args[:verify] == true && args[:subject] == book && args[:exclude] == book
        end.returns(DataImporters::Match.new(outcome: :unmatched, confidence: :high, decided_by: :rule, reason: "No candidates.", decision: new_decision))

        post recheck_admin_books_match_decision_path(@sweep)

        assert_redirected_to admin_books_match_decision_path(new_decision, compare: @sweep.id)
      end

      test "recheck of an unmatched import excludes the record it created" do
        sign_in_as(@admin, stub_auth: true)
        DataImporters::Books::Book::Finder.any_instance.expects(:call)
          .with { |args|
            args[:query].is_a?(DataImporters::Books::Book::ImportQuery) && args[:query].title == "Game of Thrones" &&
              args[:query].isbn13 == ["9780553103540"] && args[:verify] == true &&
              args[:subject].nil? && args[:exclude] == books_books(:got)
          }
          .returns(DataImporters::Match.new(outcome: :matched, record: books_books(:war_and_peace), confidence: :high, decided_by: :ai, decision: @pending))

        post recheck_admin_books_match_decision_path(@created)

        assert_redirected_to admin_books_match_decision_path(@pending, compare: @created.id)
      end

      test "recheck of a matched import excludes nothing" do
        sign_in_as(@admin, stub_auth: true)
        DataImporters::Books::Book::Finder.any_instance.expects(:call)
          .with { |args|
            args[:query].is_a?(DataImporters::Books::Book::ImportQuery) && args[:query].title == "War & Peace" &&
              args[:verify] == true && args[:subject].nil? && args[:exclude].nil?
          }
          .returns(DataImporters::Match.new(outcome: :matched, record: books_books(:war_and_peace), confidence: :certain, decided_by: :identifier, decision: @sweep))

        post recheck_admin_books_match_decision_path(@pending)

        assert_redirected_to admin_books_match_decision_path(@sweep, compare: @pending.id)
      end

      test "a viewer cannot recheck" do
        sign_in_as(@viewer, stub_auth: true)
        DataImporters::Books::Book::Finder.any_instance.expects(:call).never

        post recheck_admin_books_match_decision_path(@pending)
        assert_redirected_to books_root_path
      end

      # ---- merge into candidate N -------------------------------------------

      test "show offers Merge into candidate N for an unmatched decision with a created record, posting to the candidate's execute_action with the created record as source" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_match_decision_path(@created)

        target = books_books(:war_and_peace)
        assert_select "[data-testid=merge-into-candidate][data-candidate-index='1']" do
          assert_select "form[data-testid=merge-form][action=?][data-turbo=false]", execute_action_admin_books_book_path(target) do
            assert_select "input[name=action_name][value=MergeBook]"
            assert_select "input[name=source_book_id][value=?]", books_books(:got).id.to_s
            assert_select "input[type=checkbox][name=confirm_merge][required]"
          end
        end
      end

      test "show offers no merge for a matched decision or a sweep decision" do
        sign_in_as(@admin, stub_auth: true)

        get admin_books_match_decision_path(@pending)
        assert_select "[data-testid=merge-into-candidate]", count: 0

        get admin_books_match_decision_path(@sweep)
        assert_select "[data-testid=merge-into-candidate]", count: 0

        # @created's candidate (war_and_peace) differs from its record (got), so
        # only decision.unmatched? turning false hides it here -- pins that guard
        # on its own, unlike @pending above where self-exclusion would hide the
        # candidate regardless.
        @created.update!(outcome: :matched)
        get admin_books_match_decision_path(@created)
        assert_select "[data-testid=merge-into-candidate]", count: 0
      end

      test "show excludes a candidate that is the decision's own record but keeps a different one" do
        sign_in_as(@admin, stub_auth: true)
        got = books_books(:got)
        self_candidate = {
          "record_type" => "Books::Book", "record_id" => got.id,
          "sources" => ["opensearch"], "scores" => {}, "evidence" => {}
        }
        @created.update!(candidates: [self_candidate] + @created.candidates)

        get admin_books_match_decision_path(@created)

        # Index 1 is the self-referencing candidate (record_id == got.id ==
        # decision.record_id): the self-exclusion clause (target.id !=
        # decision.record_id) hides it. Index 2 is war_and_peace, which still
        # renders -- proving the guard excludes only the self match, not every
        # candidate.
        assert_select "[data-testid=merge-into-candidate][data-candidate-index='1']", count: 0
        assert_select "[data-testid=merge-into-candidate][data-candidate-index='2']"
      end

      test "show offers Re-check for a books decision" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_match_decision_path(@pending)

        assert_select "form[data-testid=recheck-form][action=?]", recheck_admin_books_match_decision_path(@pending)
      end
    end
  end
end
