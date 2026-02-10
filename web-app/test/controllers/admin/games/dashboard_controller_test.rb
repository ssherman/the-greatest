require "test_helper"

module Admin
  module Games
    class DashboardControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @editor_user = users(:editor_user)
        @regular_user = users(:regular_user)

        host! Rails.application.config.domains[:games]
      end

      test "should redirect to root for unauthenticated users" do
        get admin_games_root_path
        assert_redirected_to games_root_path
      end

      test "should redirect to root for regular users" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_games_root_path
        assert_redirected_to games_root_path
      end

      test "should allow admin users to access dashboard" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_root_path
        assert_response :success
      end

      test "should allow editor users to access dashboard" do
        sign_in_as(@editor_user, stub_auth: true)
        get admin_games_root_path
        assert_response :success
      end
    end
  end
end
