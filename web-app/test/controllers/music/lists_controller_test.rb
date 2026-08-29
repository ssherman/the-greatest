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
  end
end
