require "test_helper"

module Admin
  module Games
    class DuplicateCandidatesControllerTest < ActionDispatch::IntegrationTest
      setup do
        host! Rails.application.config.domains[:games]
        sign_in_as(users(:admin_user), stub_auth: true)
      end

      test "index shows the pending games pair and none of books'" do
        get admin_games_duplicate_candidates_path

        assert_response :success
        ids = css_select("[data-testid=pair-row]").map { |row| row["data-pair-id"].to_i }
        assert_equal [duplicate_candidates(:resident_evil_4_pair).id], ids
        assert_select "[data-testid=merge-a-into-b] form[action=?]", merge_admin_games_duplicate_candidate_path(duplicate_candidates(:resident_evil_4_pair))
      end

      test "merge runs the games merge action and returns to the page" do
        GenerateUserFavoritesListsJob.stubs(:perform_async)
        pair = duplicate_candidates(:resident_evil_4_pair)
        source = ::Games::Game.find(pair.item_a_id)
        target = ::Games::Game.find(pair.item_b_id)

        post merge_admin_games_duplicate_candidate_path(pair),
          params: {source_id: source.id, target_id: target.id, confirm_merge: "1", return_to: admin_games_duplicate_candidates_path(page: 1)}

        assert_redirected_to admin_games_duplicate_candidates_path(page: 1)
        assert_not ::Games::Game.exists?(source.id)
        assert pair.reload.merged?
      end

      test "an editor with write but no delete permission sees the dismiss form but no merge forms" do
        sign_in_as(users(:games_editor_user), stub_auth: true)
        get admin_games_duplicate_candidates_path

        assert_response :success
        assert_select "form[data-testid=dismiss-form]"
        assert_select "form[data-testid=merge-form]", count: 0
      end
    end
  end
end
