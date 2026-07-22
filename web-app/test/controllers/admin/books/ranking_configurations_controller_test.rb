require "test_helper"

module Admin
  module Books
    class RankingConfigurationsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        @rc = ranking_configurations(:books_global)
        host! Rails.application.config.domains[:books]
      end

      test "index redirects unauthenticated users" do
        get admin_books_ranking_configurations_path
        assert_redirected_to books_root_path
      end

      test "index redirects a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_ranking_configurations_path
        assert_redirected_to books_root_path
      end

      test "index allows an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_ranking_configurations_path
        assert_response :success
      end

      test "index allows a books domain viewer to read" do
        @regular_user.domain_roles.create!(domain: :books, permission_level: :viewer)
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_ranking_configurations_path
        assert_response :success
      end

      test "show for an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_ranking_configuration_path(@rc)
        assert_response :success
      end

      test "index tolerates a sort-injection attempt" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_nothing_raised do
          get admin_books_ranking_configurations_path(sort: "'; DROP TABLE ranking_configurations; --")
        end
        assert_response :success
      end

      test "creates a ranking configuration for an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_difference("::Books::RankingConfiguration.count", 1) do
          post admin_books_ranking_configurations_path, params: {ranking_configuration: {name: "New Books RC"}}
        end
        assert_redirected_to admin_books_ranking_configuration_path(::Books::RankingConfiguration.order(:id).last)
      end

      test "does not allow a books editor to create (manage required)" do
        @regular_user.domain_roles.create!(domain: :books, permission_level: :editor)
        sign_in_as(@regular_user, stub_auth: true)
        assert_no_difference("::Books::RankingConfiguration.count") do
          post admin_books_ranking_configurations_path, params: {ranking_configuration: {name: "Nope"}}
        end
      end
    end
  end
end
