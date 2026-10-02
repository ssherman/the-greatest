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
        assert_select "[data-testid=merge-a-into-b] input[name=action_name][value=MergeGame]"
        assert_select "[data-testid=merge-a-into-b] input[name=source_game_id]"
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
