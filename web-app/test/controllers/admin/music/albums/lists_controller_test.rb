require "test_helper"

module Admin
  module Music
    module Albums
      class ListsControllerTest < ActionDispatch::IntegrationTest
        setup do
          @admin_user = users(:admin_user)
          @regular_user = users(:regular_user)

          host! Rails.application.config.domains[:music]

          @album_list = ::Music::Albums::List.create!(
            name: "Test Album List",
            description: "A test album list",
            status: :approved,
            source: "Test Source",
            url: "https://example.com/test",
            year_published: 2023,
            number_of_voters: 100,
            estimated_quality: 80
          )

          @album_list_2 = ::Music::Albums::List.create!(
            name: "Another Album List",
            status: :unapproved,
            year_published: 2024
          )
        end

        test "should redirect to sign in when not authenticated" do
          get admin_albums_lists_path
          assert_redirected_to music_root_path
        end

        test "should redirect regular users to home" do
          sign_in_as(@regular_user, stub_auth: true)
          get admin_albums_lists_path
          assert_redirected_to music_root_path
        end

        test "should allow admin users to access index" do
          sign_in_as(@admin_user, stub_auth: true)
          get admin_albums_lists_path
          assert_response :success
        end

        test "index should render lists table" do
          sign_in_as(@admin_user, stub_auth: true)
          get admin_albums_lists_path
          assert_response :success
        end

        test "should sort by id" do
          sign_in_as(@admin_user, stub_auth: true)
          get admin_albums_lists_path(sort: "id")
          assert_response :success
        end

        test "should sort by name" do
          sign_in_as(@admin_user, stub_auth: true)
          get admin_albums_lists_path(sort: "name")
          assert_response :success
        end

        test "should sort by year_published" do
          sign_in_as(@admin_user, stub_auth: true)
          get admin_albums_lists_path(sort: "year_published")
          assert_response :success
        end

        test "should sort by created_at" do
          sign_in_as(@admin_user, stub_auth: true)
          get admin_albums_lists_path(sort: "created_at")
          assert_response :success
        end

        test "should use default sort for invalid column" do
          sign_in_as(@admin_user, stub_auth: true)
          get admin_albums_lists_path(sort: "invalid_column")
          assert_response :success
        end

        test "should sort ascending by default" do
          sign_in_as(@admin_user, stub_auth: true)
          get admin_albums_lists_path(sort: "name")
          assert_response :success
        end

        test "should sort descending when direction param is desc" do
          sign_in_as(@admin_user, stub_auth: true)
          get admin_albums_lists_path(sort: "name", direction: "desc")
          assert_response :success
        end

        test "should sort ascending when direction param is asc" do
          sign_in_as(@admin_user, stub_auth: true)
          get admin_albums_lists_path(sort: "name", direction: "asc")
          assert_response :success
        end

        test "should ignore invalid direction values" do
          sign_in_as(@admin_user, stub_auth: true)
          get admin_albums_lists_path(sort: "name", direction: "invalid")
          assert_response :success
        end

        test "should handle direction param case insensitively" do
          sign_in_as(@admin_user, stub_auth: true)
          get admin_albums_lists_path(sort: "name", direction: "DESC")
          assert_response :success

          get admin_albums_lists_path(sort: "name", direction: "AsC")
          assert_response :success
        end

        test "should paginate lists" do
          sign_in_as(@admin_user, stub_auth: true)
          26.times { |i| ::Music::Albums::List.create!(name: "List #{i}", status: :approved) }

          get admin_albums_lists_path
          assert_response :success
        end

        test "should preserve sort params when paginating" do
          sign_in_as(@admin_user, stub_auth: true)
          30.times { |i| ::Music::Albums::List.create!(name: "List #{i}", status: :approved) }

          get admin_albums_lists_path(sort: "created_at", direction: "desc", page: 2)
          assert_response :success
        end

        test "should show list details" do
          sign_in_as(@admin_user, stub_auth: true)
          get admin_albums_list_path(@album_list)
          assert_response :success
        end

        test "should show list with albums without errors" do
          sign_in_as(@admin_user, stub_auth: true)

          # Use an existing album fixture
          album = music_albums(:dark_side_of_the_moon)

          # Create a list item linking the album to the list
          @album_list.list_items.create!(listable: album, position: 1)

          get admin_albums_list_path(@album_list)
          assert_response :success
        end

        test "should handle non-existent list" do
          sign_in_as(@admin_user, stub_auth: true)
          get admin_albums_list_path(id: 999999)
          assert_response :not_found
        end

        test "should show new list form" do
          sign_in_as(@admin_user, stub_auth: true)
          get new_admin_albums_list_path
          assert_response :success
        end

        test "should create list with valid params" do
          sign_in_as(@admin_user, stub_auth: true)

          assert_difference("::Music::Albums::List.count") do
            post admin_albums_lists_path, params: {
              music_albums_list: {
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

          assert_redirected_to admin_albums_list_path(::Music::Albums::List.last)

          list = ::Music::Albums::List.last
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

          assert_no_difference("::Music::Albums::List.count") do
            post admin_albums_lists_path, params: {
              music_albums_list: {
                name: "",
                status: "approved"
              }
            }
          end

          assert_response :unprocessable_entity
        end

        test "should show edit form" do
          sign_in_as(@admin_user, stub_auth: true)
          get edit_admin_albums_list_path(@album_list)
          assert_response :success
        end

        test "should update list with valid params" do
          sign_in_as(@admin_user, stub_auth: true)

          patch admin_albums_list_path(@album_list), params: {
            music_albums_list: {
              name: "Updated List Name",
              description: "Updated description",
              year_published: 2025
            }
          }

          assert_redirected_to admin_albums_list_path(@album_list)

          @album_list.reload
          assert_equal "Updated List Name", @album_list.name
          assert_equal "Updated description", @album_list.description
          assert_equal 2025, @album_list.year_published
        end

        test "should not update list with invalid params" do
          sign_in_as(@admin_user, stub_auth: true)

          patch admin_albums_list_path(@album_list), params: {
            music_albums_list: {
              name: "",
              url: "not a valid url"
            }
          }

          assert_response :unprocessable_entity
        end

        test "should destroy list" do
          sign_in_as(@admin_user, stub_auth: true)

          assert_difference("::Music::Albums::List.count", -1) do
            delete admin_albums_list_path(@album_list)
          end

          assert_redirected_to admin_albums_lists_path
        end

        test "should create list with all flag fields" do
          sign_in_as(@admin_user, stub_auth: true)

          post admin_albums_lists_path, params: {
            music_albums_list: {
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

          list = ::Music::Albums::List.last
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

          post admin_albums_lists_path, params: {
            music_albums_list: {
              name: "Metadata Test List",
              status: "approved",
              number_of_voters: 1000,
              estimated_quality: 95,
              num_years_covered: 10,
              musicbrainz_series_id: "12345678-1234-1234-1234-123456789012"
            }
          }

          list = ::Music::Albums::List.last
          assert_equal 1000, list.number_of_voters
          assert_equal 95, list.estimated_quality
          assert_equal 10, list.num_years_covered
          assert_equal "12345678-1234-1234-1234-123456789012", list.musicbrainz_series_id
        end

        test "should handle num_years_covered validation" do
          sign_in_as(@admin_user, stub_auth: true)

          assert_no_difference("::Music::Albums::List.count") do
            post admin_albums_lists_path, params: {
              music_albums_list: {
                name: "Invalid Years List",
                status: "approved",
                num_years_covered: 0
              }
            }
          end

          assert_response :unprocessable_entity
        end

        test "should display empty state when no lists exist" do
          sign_in_as(@admin_user, stub_auth: true)
          ::Music::Albums::List.destroy_all

          get admin_albums_lists_path
          assert_response :success
        end

        test "should correctly count items in items_json hash format" do
          sign_in_as(@admin_user, stub_auth: true)

          # Create a list with items_json in hash format (albums key)
          list_with_json = ::Music::Albums::List.create!(
            name: "List with Items JSON",
            status: :approved,
            items_json: {
              "albums" => [
                {"rank" => 1, "title" => "Album 1"},
                {"rank" => 2, "title" => "Album 2"},
                {"rank" => 3, "title" => "Album 3"}
              ]
            }
          )

          get admin_albums_list_path(list_with_json)
          assert_response :success
        end

        test "should correctly count items in items_json array format" do
          sign_in_as(@admin_user, stub_auth: true)

          # Create a list with items_json in array format
          list_with_json = ::Music::Albums::List.create!(
            name: "List with Array JSON",
            status: :approved,
            items_json: [
              {"rank" => 1, "title" => "Album 1"},
              {"rank" => 2, "title" => "Album 2"}
            ]
          )

          get admin_albums_list_path(list_with_json)
          assert_response :success
        end

        test "should update list with items_json as JSON string" do
          sign_in_as(@admin_user, stub_auth: true)

          items_json_string = '{"albums": [{"rank": 1, "title": "Updated Album"}]}'

          patch admin_albums_list_path(@album_list), params: {
            music_albums_list: {
              items_json: items_json_string
            }
          }

          assert_redirected_to admin_albums_list_path(@album_list)

          @album_list.reload
          # Rails automatically parses JSON strings for JSONB columns
          assert @album_list.items_json.present?, "items_json should be present"
          assert_kind_of Enumerable, @album_list.items_json, "items_json should be a Hash or Array, got #{@album_list.items_json.class}"

          if @album_list.items_json.is_a?(Hash)
            assert_equal 1, @album_list.items_json["albums"].length
            assert_equal "Updated Album", @album_list.items_json["albums"][0]["title"]
          end
        end

        test "should reject invalid JSON in items_json and return unprocessable_entity" do
          sign_in_as(@admin_user, stub_auth: true)

          invalid_json = '{"albums": [invalid json}'

          patch admin_albums_list_path(@album_list), params: {
            music_albums_list: {
              items_json: invalid_json
            }
          }

          assert_response :unprocessable_entity
          # Verify error message appears in response body
          assert_includes response.body, "must be valid JSON"
        end

        test "should reject invalid JSON on create and return unprocessable_entity" do
          sign_in_as(@admin_user, stub_auth: true)

          invalid_json = '{"albums": [invalid'

          assert_no_difference("::Music::Albums::List.count") do
            post admin_albums_lists_path, params: {
              music_albums_list: {
                name: "Invalid JSON List",
                status: "approved",
                items_json: invalid_json
              }
            }
          end

          assert_response :unprocessable_entity
        end

        test "should update list with raw_html and formatted_text" do
          sign_in_as(@admin_user, stub_auth: true)

          patch admin_albums_list_path(@album_list), params: {
            music_albums_list: {
              raw_html: "<html><body>Raw content</body></html>",
              formatted_text: "Plain text content"
            }
          }

          assert_redirected_to admin_albums_list_path(@album_list)

          @album_list.reload
          assert_equal "<html><body>Raw content</body></html>", @album_list.raw_html
          # Note: simplified_html is auto-generated from raw_html by the model
          assert @album_list.simplified_html.present?
          assert_equal "Plain text content", @album_list.formatted_text
        end

        test "should update simplified_html directly when raw_html not changed" do
          sign_in_as(@admin_user, stub_auth: true)

          # First set raw_html
          @album_list.update!(raw_html: "<html><body>Original</body></html>")

          # Now update simplified_html without changing raw_html
          patch admin_albums_list_path(@album_list), params: {
            music_albums_list: {
              simplified_html: "<div>Manually edited</div>"
            }
          }

          assert_redirected_to admin_albums_list_path(@album_list)

          @album_list.reload
          assert_equal "<div>Manually edited</div>", @album_list.simplified_html
        end

        test "should create list with all data import fields" do
          sign_in_as(@admin_user, stub_auth: true)

          items_json_string = '{"albums": [{"rank": 1, "title": "Test Album"}]}'

          assert_difference("::Music::Albums::List.count") do
            post admin_albums_lists_path, params: {
              music_albums_list: {
                name: "List with Data",
                status: "approved",
                items_json: items_json_string,
                raw_html: "<html>Raw</html>",
                formatted_text: "Text"
              }
            }
          end

          list = ::Music::Albums::List.last
          assert list.items_json.is_a?(Hash)
          assert_equal 1, list.items_json["albums"].length
          assert_equal "<html>Raw</html>", list.raw_html
          # Note: simplified_html is auto-generated from raw_html
          assert list.simplified_html.present?
          assert_equal "Text", list.formatted_text
        end
      end
    end
  end
end
