require "test_helper"

module Admin
  module Music
    class MatchDecisionsControllerTest < ActionDispatch::IntegrationTest
      setup do
        host! Rails.application.config.domains[:music]
        sign_in_as(users(:admin_user), stub_auth: true)
      end

      test "index shows music finders' decisions and none of books'" do
        get admin_match_decisions_path

        assert_response :success
        ids = css_select("[data-testid=decision-row]").map { |row| row["data-decision-id"].to_i }
        assert_equal [match_decisions(:dark_side_album_match).id], ids
      end

      test "show renders a music decision" do
        get admin_match_decision_path(match_decisions(:dark_side_album_match))
        assert_response :success
      end

      test "recheck is refused for a finder whose real sources have not landed, and no Re-check form renders" do
        decision = match_decisions(:dark_side_album_match)
        DataImporters::Music::Album::Finder.any_instance.expects(:call).never

        get admin_match_decision_path(decision)
        assert_select "form[data-testid=recheck-form]", count: 0

        post recheck_admin_match_decision_path(decision)
        assert_redirected_to admin_match_decision_path(decision)
        assert_equal 1, MatchDecision.where(finder: "DataImporters::Music::Album::Finder").count
      end
    end
  end
end
