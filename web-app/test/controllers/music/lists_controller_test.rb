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

    test "index does not show a non-active album list even when weighted" do
      list = ::Music::Albums::List.create!(name: "Approved But Not Active", status: :approved)
      ::RankedList.create!(list: list, ranking_configuration: ranking_configurations(:music_albums_global), weight: 999)

      get "/lists"

      assert_response :success
      assert_no_match "Approved But Not Active", response.body
    end

    test "index does not show a non-active song list even when weighted" do
      list = ::Music::Songs::List.create!(name: "Approved But Not Active Song List", status: :approved)
      ::RankedList.create!(list: list, ranking_configuration: ranking_configurations(:music_songs_global), weight: 999)

      get "/lists"

      assert_response :success
      assert_no_match "Approved But Not Active Song List", response.body
    end
  end
end
