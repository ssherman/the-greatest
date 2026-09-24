require "test_helper"

module Admin
  module Music
    class DuplicateCandidatesControllerTest < ActionDispatch::IntegrationTest
      setup do
        host! Rails.application.config.domains[:music]
        sign_in_as(users(:admin_user), stub_auth: true)
      end

      test "index renders empty for music" do
        get admin_duplicate_candidates_path

        assert_response :success
        assert_select "[data-testid=pair-row]", count: 0
      end
    end
  end
end
