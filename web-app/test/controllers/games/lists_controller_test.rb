require "test_helper"

module Games
  class ListsControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev.thegreatest.games"
    end

    test "should get index" do
      get "/lists"
      assert_response :success
    end
  end
end
