require "test_helper"

module Music
  class ListsControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev.thegreatestmusic.org"
      @user = users(:regular_user)
    end

    test "should get index" do
      get "/lists"
      assert_response :success
    end

    test "should render successfully with album and song lists" do
      get "/lists"
      assert_response :success
      assert_select "h2", text: "Top Album Lists"
      assert_select "h2", text: "Top Song Lists"
    end

    test "index should have submit a list link" do
      get "/lists"
      assert_response :success
      assert_select "a[href=?]", "/lists/new"
    end

    test "should get new" do
      get "/lists/new"
      assert_response :success
    end

    test "new should render submission form" do
      get "/lists/new"
      assert_response :success
      assert_select "h1", text: "Submit a Music List"
    end

    test "should create album list as anonymous user" do
      assert_difference("Music::Albums::List.count", 1) do
        post "/lists", params: {
          list_type: "albums",
          list: {
            name: "Test Album List",
            description: "A test list",
            source: "Test Source"
          }
        }
      end

      list = Music::Albums::List.last
      assert_equal "Test Album List", list.name
      assert_equal "unapproved", list.status
      assert_nil list.submitted_by_id

      assert_redirected_to music_lists_path
      assert_equal "Thank you for your submission! Your list will be reviewed shortly.", flash[:notice]
    end

    test "should create song list as anonymous user" do
      assert_difference("Music::Songs::List.count", 1) do
        post "/lists", params: {
          list_type: "songs",
          list: {
            name: "Test Song List",
            source: "Test Source"
          }
        }
      end

      list = Music::Songs::List.last
      assert_equal "Test Song List", list.name
      assert_equal "unapproved", list.status
      assert_nil list.submitted_by_id

      assert_redirected_to music_lists_path
    end

    test "should create list with logged in user setting submitted_by_id" do
      sign_in_as(@user, stub_auth: true)

      assert_difference("Music::Albums::List.count", 1) do
        post "/lists", params: {
          list_type: "albums",
          list: {
            name: "User Submitted List"
          }
        }
      end

      list = Music::Albums::List.last
      assert_equal @user.id, list.submitted_by_id
      assert_redirected_to music_lists_path
    end

    test "should fail without list_type" do
      assert_no_difference("List.count") do
        post "/lists", params: {
          list: {
            name: "Test List"
          }
        }
      end

      assert_response :unprocessable_entity
    end

    test "should fail with missing required name" do
      assert_no_difference("List.count") do
        post "/lists", params: {
          list_type: "albums",
          list: {
            description: "A list without a name"
          }
        }
      end

      assert_response :unprocessable_entity
    end

    test "should fail with invalid url format" do
      assert_no_difference("List.count") do
        post "/lists", params: {
          list_type: "albums",
          list: {
            name: "Test List",
            url: "not-a-valid-url"
          }
        }
      end

      assert_response :unprocessable_entity
    end

    test "should accept all list attributes" do
      assert_difference("Music::Albums::List.count", 1) do
        post "/lists", params: {
          list_type: "albums",
          list: {
            name: "Complete List",
            description: "Full description",
            source: "Rolling Stone",
            url: "https://example.com/list",
            year_published: 2024,
            number_of_voters: 300,
            num_years_covered: 50,
            location_specific: true,
            category_specific: false,
            yearly_award: true,
            voter_count_estimated: true,
            voter_names_unknown: false,
            voter_count_unknown: false,
            raw_html: "1. Test Album - Test Artist\n2. Another Album - Another Artist"
          }
        }
      end

      list = Music::Albums::List.last
      assert_equal "Complete List", list.name
      assert_equal "Full description", list.description
      assert_equal "Rolling Stone", list.source
      assert_equal "https://example.com/list", list.url
      assert_equal 2024, list.year_published
      assert_equal 300, list.number_of_voters
      assert_equal 50, list.num_years_covered
      assert list.location_specific
      assert_not list.category_specific
      assert list.yearly_award
      assert list.voter_count_estimated
      assert_not list.voter_names_unknown
      assert_not list.voter_count_unknown
      assert_includes list.raw_html, "Test Album"
    end
  end
end
