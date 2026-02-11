require "test_helper"

module Admin
  module Games
    class CompaniesControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        @company = games_companies(:nintendo)

        host! Rails.application.config.domains[:games]
      end

      # Authentication Tests

      test "should redirect index to root for unauthenticated users" do
        get admin_games_companies_path
        assert_redirected_to games_root_path
      end

      test "should redirect to root for regular users" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_games_companies_path
        assert_redirected_to games_root_path
      end

      test "should allow admin users to access index" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_companies_path
        assert_response :success
      end

      # Index Tests

      test "should get index with search query" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_companies_path(q: "Nintendo")
        assert_response :success
      end

      test "should handle sorting" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_companies_path(sort: "name")
        assert_response :success
      end

      test "should reject invalid sort parameters" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_nothing_raised do
          get admin_games_companies_path(sort: "'; DROP TABLE games_companies; --")
        end
        assert_response :success
      end

      # Show Tests

      test "should get show for admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_company_path(@company)
        assert_response :success
      end

      test "should not get show for regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_games_company_path(@company)
        assert_redirected_to games_root_path
      end

      # Create Tests

      test "should create company for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        assert_difference("::Games::Company.count", 1) do
          post admin_games_companies_path, params: {
            games_company: {
              name: "New Studio",
              country: "US",
              year_founded: 2020
            }
          }
        end

        assert_redirected_to admin_games_company_path(::Games::Company.last)
      end

      test "should not create company with invalid data" do
        sign_in_as(@admin_user, stub_auth: true)

        assert_no_difference("::Games::Company.count") do
          post admin_games_companies_path, params: {
            games_company: {name: ""}
          }
        end

        assert_response :unprocessable_entity
      end

      # Update Tests

      test "should update company for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        patch admin_games_company_path(@company), params: {
          games_company: {name: "Updated Nintendo"}
        }

        assert_redirected_to admin_games_company_path(@company)
        @company.reload
        assert_equal "Updated Nintendo", @company.name
      end

      # Destroy Tests

      test "should destroy company for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        assert_difference("::Games::Company.count", -1) do
          delete admin_games_company_path(@company)
        end

        assert_redirected_to admin_games_companies_path
      end

      # Search Tests

      test "should return JSON search results" do
        sign_in_as(@admin_user, stub_auth: true)
        get search_admin_games_companies_path(q: "Nint"), as: :json
        assert_response :success

        json_response = JSON.parse(response.body)
        assert json_response.any? { |r| r["text"].include?("Nintendo") }
      end
    end
  end
end
