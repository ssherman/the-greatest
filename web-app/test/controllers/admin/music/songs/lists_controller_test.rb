require "test_helper"

module Admin
  module Music
    module Songs
      class ListsControllerTest < ActionDispatch::IntegrationTest
        setup do
          host! Rails.application.config.domains[:music]
          @admin = users(:admin_user)
          sign_in_as(@admin, stub_auth: true)
        end

        test "should get index" do
          get admin_songs_lists_path
          assert_response :success
        end

        test "should get index with pagination" do
          get admin_songs_lists_path
          assert_response :success
        end

        test "should sort by id ascending" do
          get admin_songs_lists_path(sort: "id", direction: "asc")
          assert_response :success
        end

        test "should sort by id descending" do
          get admin_songs_lists_path(sort: "id", direction: "desc")
          assert_response :success
        end

        test "should sort by name ascending" do
          get admin_songs_lists_path(sort: "name", direction: "asc")
          assert_response :success
        end

        test "should sort by name descending" do
          get admin_songs_lists_path(sort: "name", direction: "desc")
          assert_response :success
        end

        test "should sort by year_published ascending" do
          get admin_songs_lists_path(sort: "year_published", direction: "asc")
          assert_response :success
        end

        test "should sort by year_published descending" do
          get admin_songs_lists_path(sort: "year_published", direction: "desc")
          assert_response :success
        end

        test "should sort by created_at ascending" do
          get admin_songs_lists_path(sort: "created_at", direction: "asc")
          assert_response :success
        end

        test "should sort by created_at descending" do
          get admin_songs_lists_path(sort: "created_at", direction: "desc")
          assert_response :success
        end

        test "should ignore invalid sort column" do
          get admin_songs_lists_path(sort: "invalid_column", direction: "asc")
          assert_response :success
        end

        test "should ignore invalid sort direction" do
          get admin_songs_lists_path(sort: "name", direction: "invalid")
          assert_response :success
        end

        # Status filter tests
        test "should filter by status all" do
          get admin_songs_lists_path(status: "all")
          assert_response :success
        end

        test "should filter by status unapproved" do
          ::Music::Songs::List.create!(name: "Unapproved List", status: :unapproved)
          get admin_songs_lists_path(status: "unapproved")
          assert_response :success
        end

        test "should filter by status approved" do
          ::Music::Songs::List.create!(name: "Approved List", status: :approved)
          get admin_songs_lists_path(status: "approved")
          assert_response :success
        end

        test "should filter by status rejected" do
          ::Music::Songs::List.create!(name: "Rejected List", status: :rejected)
          get admin_songs_lists_path(status: "rejected")
          assert_response :success
        end

        test "should filter by status active" do
          ::Music::Songs::List.create!(name: "Active List", status: :active)
          get admin_songs_lists_path(status: "active")
          assert_response :success
        end

        test "should handle invalid status filter gracefully" do
          get admin_songs_lists_path(status: "invalid_status")
          assert_response :success
        end

        test "should preserve status filter in pagination" do
          26.times { |i| ::Music::Songs::List.create!(name: "List #{i}", status: :approved) }
          get admin_songs_lists_path(status: "approved", page: 2)
          assert_response :success
        end

        test "should preserve status filter when sorting" do
          get admin_songs_lists_path(status: "approved", sort: "name", direction: "desc")
          assert_response :success
        end

        # Search tests
        test "should search by name" do
          ::Music::Songs::List.create!(name: "Rolling Stone Best Songs", status: :approved)
          ::Music::Songs::List.create!(name: "Billboard Top 100", status: :approved)
          get admin_songs_lists_path(q: "rolling")
          assert_response :success
          assert_select "td", text: /Rolling Stone/
        end

        test "should search case-insensitively" do
          ::Music::Songs::List.create!(name: "Rolling Stone Best Songs", status: :approved)
          get admin_songs_lists_path(q: "ROLLING")
          assert_response :success
          assert_select "td", text: /Rolling Stone/
        end

        test "should combine search with status filter" do
          ::Music::Songs::List.create!(name: "Rolling Stone Approved", status: :approved)
          ::Music::Songs::List.create!(name: "Rolling Stone Rejected", status: :rejected)
          get admin_songs_lists_path(q: "rolling", status: "approved")
          assert_response :success
        end

        test "should return all lists when search is blank" do
          get admin_songs_lists_path(q: "")
          assert_response :success
        end

        test "should preserve search query in pagination" do
          26.times { |i| ::Music::Songs::List.create!(name: "Rolling List #{i}", status: :approved) }
          get admin_songs_lists_path(q: "rolling", page: 2)
          assert_response :success
        end

        test "should get new" do
          get new_admin_songs_list_path
          assert_response :success
        end

        test "should create list with valid data" do
          assert_difference("::Music::Songs::List.count") do
            post admin_songs_lists_path, params: {
              music_songs_list: {
                name: "Test Song List",
                status: "active",
                source: "Test Source",
                url: "https://example.com/test-list",
                year_published: 2024
              }
            }
          end
          assert_redirected_to admin_songs_list_path(::Music::Songs::List.last)
        end

        test "should not create list without name" do
          assert_no_difference("::Music::Songs::List.count") do
            post admin_songs_lists_path, params: {
              music_songs_list: {
                status: "active"
              }
            }
          end
          assert_response :unprocessable_entity
        end

        test "should not create list with invalid url format" do
          assert_no_difference("::Music::Songs::List.count") do
            post admin_songs_lists_path, params: {
              music_songs_list: {
                name: "Test List",
                status: "active",
                url: "not-a-valid-url"
              }
            }
          end
          assert_response :unprocessable_entity
        end

        test "should get show" do
          list = ::Music::Songs::List.create!(name: "Test List", status: "active")
          get admin_songs_list_path(list)
          assert_response :success
        end

        test "should get edit" do
          list = ::Music::Songs::List.create!(name: "Test List", status: "active")
          get edit_admin_songs_list_path(list)
          assert_response :success
        end

        test "should update list with valid data" do
          list = ::Music::Songs::List.create!(name: "Original Name", status: "active")
          patch admin_songs_list_path(list), params: {
            music_songs_list: {
              name: "Updated Name"
            }
          }
          assert_redirected_to admin_songs_list_path(list)
          list.reload
          assert_equal "Updated Name", list.name
        end

        test "should not update list with invalid data" do
          list = ::Music::Songs::List.create!(name: "Original Name", status: "active")
          patch admin_songs_list_path(list), params: {
            music_songs_list: {
              name: ""
            }
          }
          assert_response :unprocessable_entity
          list.reload
          assert_equal "Original Name", list.name
        end

        test "should destroy list" do
          list = ::Music::Songs::List.create!(name: "Test List", status: "active")
          assert_difference("::Music::Songs::List.count", -1) do
            delete admin_songs_list_path(list)
          end
          assert_redirected_to admin_songs_lists_path
        end

        test "should handle all boolean flags" do
          post admin_songs_lists_path, params: {
            music_songs_list: {
              name: "Flags Test List",
              status: "active",
              high_quality_source: true,
              category_specific: true,
              location_specific: true,
              yearly_award: true,
              voter_count_estimated: true,
              voter_count_unknown: true,
              voter_names_unknown: true
            }
          }
          list = ::Music::Songs::List.last
          assert list.high_quality_source
          assert list.category_specific
          assert list.location_specific
          assert list.yearly_award
          assert list.voter_count_estimated
          assert list.voter_count_unknown
          assert list.voter_names_unknown
        end

        test "should handle metadata fields" do
          post admin_songs_lists_path, params: {
            music_songs_list: {
              name: "Metadata Test List",
              status: "active",
              number_of_voters: 100,
              estimated_quality: 85,
              num_years_covered: 10,
              musicbrainz_series_id: "12345678-1234-1234-1234-123456789012"
            }
          }
          list = ::Music::Songs::List.last
          assert_equal 100, list.number_of_voters
          assert_equal 85, list.estimated_quality
          assert_equal 10, list.num_years_covered
          assert_equal "12345678-1234-1234-1234-123456789012", list.musicbrainz_series_id
        end

        test "items_json is not settable via admin form params" do
          json_string = '{"songs": [{"rank": 1, "title": "Test Song", "artist": "Test Artist"}]}'
          post admin_songs_lists_path, params: {
            music_songs_list: {
              name: "JSON Test List",
              status: "active",
              items_json: json_string
            }
          }
          list = ::Music::Songs::List.last
          assert_nil list.items_json
        end

        test "should handle raw_content field" do
          post admin_songs_lists_path, params: {
            music_songs_list: {
              name: "Raw Content Test List",
              status: "active",
              raw_content: "<html><body>Test</body></html>"
            }
          }
          list = ::Music::Songs::List.last
          assert_equal "<html><body>Test</body></html>", list.raw_content
        end

        test "should handle simplified_content field" do
          post admin_songs_lists_path, params: {
            music_songs_list: {
              name: "Simplified Content Test List",
              status: "active",
              simplified_content: "<p>Simplified content</p>"
            }
          }
          list = ::Music::Songs::List.last
          assert_equal "<p>Simplified content</p>", list.simplified_content
        end
      end
    end
  end
end
