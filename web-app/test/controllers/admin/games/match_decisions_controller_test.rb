require "test_helper"

module Admin
  module Games
    class MatchDecisionsControllerTest < ActionDispatch::IntegrationTest
      setup do
        host! Rails.application.config.domains[:games]
        sign_in_as(users(:admin_user), stub_auth: true)
      end

      test "index renders with no games decisions and lists both games entities in the filter" do
        get admin_games_match_decisions_path

        assert_response :success
        assert_select "[data-testid=decision-row]", count: 0
        assert_select "select[name=entity] option[value=game]"
        assert_select "select[name=entity] option[value=company]"
      end
    end
  end
end
