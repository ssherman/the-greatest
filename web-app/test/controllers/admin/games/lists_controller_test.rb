require "test_helper"

module Admin
  module Games
    class ListsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)

        host! Rails.application.config.domains[:games]

        @games_list = ::Games::List.create!(
          name: "Test Games List",
          description: "A test games list",
          status: :approved,
          source: "Test Source",
          url: "https://example.com/test",
          year_published: 2023,
          number_of_voters: 100,
          estimated_quality: 80
        )

        @games_list_2 = ::Games::List.create!(
          name: "Another Games List",
          status: :unapproved,
          year_published: 2024
        )
      end

      test "should redirect to sign in when not authenticated" do
        get admin_games_lists_path
        assert_redirected_to games_root_path
      end

      test "should redirect regular users to home" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_games_lists_path
        assert_redirected_to games_root_path
      end

      test "should allow admin users to access index" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_lists_path
        assert_response :success
      end

      test "index should render lists table" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_lists_path
        assert_response :success
      end

      test "should sort by id" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_lists_path(sort: "id")
        assert_response :success
      end

      test "should sort by name" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_lists_path(sort: "name")
        assert_response :success
      end

      test "should sort by year_published" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_lists_path(sort: "year_published")
        assert_response :success
      end

      test "should sort by created_at" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_lists_path(sort: "created_at")
        assert_response :success
      end

      test "should use default sort for invalid column" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_lists_path(sort: "invalid_column")
        assert_response :success
      end

      test "should sort ascending by default" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_lists_path(sort: "name")
        assert_response :success
      end

      test "should sort descending when direction param is desc" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_lists_path(sort: "name", direction: "desc")
        assert_response :success
      end

      test "should sort ascending when direction param is asc" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_lists_path(sort: "name", direction: "asc")
        assert_response :success
      end

      test "should ignore invalid direction values" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_lists_path(sort: "name", direction: "invalid")
        assert_response :success
      end

      test "should handle direction param case insensitively" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_lists_path(sort: "name", direction: "DESC")
        assert_response :success

        get admin_games_lists_path(sort: "name", direction: "AsC")
        assert_response :success
      end

      # Status filter tests
      test "should filter by status all" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_lists_path(status: "all")
        assert_response :success
      end

      test "should filter by status unapproved" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_lists_path(status: "unapproved")
        assert_response :success
      end

      test "should filter by status approved" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_lists_path(status: "approved")
        assert_response :success
      end

      test "should filter by status rejected" do
        sign_in_as(@admin_user, stub_auth: true)
        ::Games::List.create!(name: "Rejected List", status: :rejected)
        get admin_games_lists_path(status: "rejected")
        assert_response :success
      end

      test "should filter by status active" do
        sign_in_as(@admin_user, stub_auth: true)
        ::Games::List.create!(name: "Active List", status: :active)
        get admin_games_lists_path(status: "active")
        assert_response :success
      end

      test "should handle invalid status filter gracefully" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_lists_path(status: "invalid_status")
        assert_response :success
      end

      test "should preserve status filter in pagination" do
        sign_in_as(@admin_user, stub_auth: true)
        26.times { |i| ::Games::List.create!(name: "Paginated List #{i}", status: :approved) }
        get admin_games_lists_path(status: "approved", page: 2)
        assert_response :success
      end

      test "should preserve status filter when sorting" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_lists_path(status: "approved", sort: "name", direction: "desc")
        assert_response :success
      end

      test "should paginate lists" do
        sign_in_as(@admin_user, stub_auth: true)
        26.times { |i| ::Games::List.create!(name: "List #{i}", status: :approved) }

        get admin_games_lists_path
        assert_response :success
      end

      test "should preserve sort params when paginating" do
        sign_in_as(@admin_user, stub_auth: true)
        30.times { |i| ::Games::List.create!(name: "List #{i}", status: :approved) }

        get admin_games_lists_path(sort: "created_at", direction: "desc", page: 2)
        assert_response :success
      end

      test "should show list details" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_list_path(@games_list)
        assert_response :success
      end

      test "should show list with games without errors" do
        sign_in_as(@admin_user, stub_auth: true)

        game = games_games(:tears_of_the_kingdom)

        @games_list.list_items.create!(listable: game, position: 1)

        get admin_games_list_path(@games_list)
        assert_response :success
      end

      test "should handle non-existent list" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_list_path(id: 999999)
        assert_response :not_found
      end

      test "should show new list form" do
        sign_in_as(@admin_user, stub_auth: true)
        get new_admin_games_list_path
        assert_response :success
      end

      test "should create list with valid params" do
        sign_in_as(@admin_user, stub_auth: true)

        assert_difference("::Games::List.count") do
          post admin_games_lists_path, params: {
            games_list: {
              name: "New Test List",
              description: "A new test list",
              status: "approved",
              source: "New Source",
              url: "https://example.com/new",
              year_published: 2024,
              high_quality_source: true,
              number_of_voters: 500
            }
          }
        end

        assert_redirected_to admin_games_list_path(::Games::List.last)

        list = ::Games::List.last
        assert_equal "New Test List", list.name
        assert_equal "A new test list", list.description
        assert_equal "approved", list.status
        assert_equal "New Source", list.source
        assert_equal 2024, list.year_published
        assert_equal true, list.high_quality_source
        assert_equal 500, list.number_of_voters
      end

      test "should not create list with invalid params" do
        sign_in_as(@admin_user, stub_auth: true)

        assert_no_difference("::Games::List.count") do
          post admin_games_lists_path, params: {
            games_list: {
              name: "",
              status: "approved"
            }
          }
        end

        assert_response :unprocessable_entity
      end

      test "should show edit form" do
        sign_in_as(@admin_user, stub_auth: true)
        get edit_admin_games_list_path(@games_list)
        assert_response :success
      end

      test "should update list with valid params" do
        sign_in_as(@admin_user, stub_auth: true)

        patch admin_games_list_path(@games_list), params: {
          games_list: {
            name: "Updated List Name",
            description: "Updated description",
            year_published: 2025
          }
        }

        assert_redirected_to admin_games_list_path(@games_list)

        @games_list.reload
        assert_equal "Updated List Name", @games_list.name
        assert_equal "Updated description", @games_list.description
        assert_equal 2025, @games_list.year_published
      end

      test "should not update list with invalid params" do
        sign_in_as(@admin_user, stub_auth: true)

        patch admin_games_list_path(@games_list), params: {
          games_list: {
            name: "",
            url: "not a valid url"
          }
        }

        assert_response :unprocessable_entity
      end

      test "should destroy list" do
        sign_in_as(@admin_user, stub_auth: true)

        assert_difference("::Games::List.count", -1) do
          delete admin_games_list_path(@games_list)
        end

        assert_redirected_to admin_games_lists_path
      end

      test "should create list with all flag fields" do
        sign_in_as(@admin_user, stub_auth: true)

        post admin_games_lists_path, params: {
          games_list: {
            name: "Flags Test List",
            status: "approved",
            high_quality_source: true,
            category_specific: true,
            location_specific: true,
            yearly_award: true,
            voter_count_estimated: true,
            voter_count_unknown: true,
            voter_names_unknown: true
          }
        }

        list = ::Games::List.last
        assert_equal true, list.high_quality_source
        assert_equal true, list.category_specific
        assert_equal true, list.location_specific
        assert_equal true, list.yearly_award
        assert_equal true, list.voter_count_estimated
        assert_equal true, list.voter_count_unknown
        assert_equal true, list.voter_names_unknown
      end

      test "should create list with metadata fields" do
        sign_in_as(@admin_user, stub_auth: true)

        post admin_games_lists_path, params: {
          games_list: {
            name: "Metadata Test List",
            status: "approved",
            number_of_voters: 1000,
            estimated_quality: 95,
            num_years_covered: 10
          }
        }

        list = ::Games::List.last
        assert_equal 1000, list.number_of_voters
        assert_equal 95, list.estimated_quality
        assert_equal 10, list.num_years_covered
      end

      test "should display empty state when no lists exist" do
        sign_in_as(@admin_user, stub_auth: true)
        ::Games::List.destroy_all

        get admin_games_lists_path
        assert_response :success
      end

      test "should update list with raw_html and formatted_text" do
        sign_in_as(@admin_user, stub_auth: true)

        patch admin_games_list_path(@games_list), params: {
          games_list: {
            raw_html: "<html><body>Raw content</body></html>",
            formatted_text: "Plain text content"
          }
        }

        assert_redirected_to admin_games_list_path(@games_list)

        @games_list.reload
        assert_equal "<html><body>Raw content</body></html>", @games_list.raw_html
        assert @games_list.simplified_html.present?
        assert_equal "Plain text content", @games_list.formatted_text
      end

      test "should search lists by name" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_lists_path(q: "Test Games")
        assert_response :success
      end
    end
  end
end
