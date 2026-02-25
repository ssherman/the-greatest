require "test_helper"

module Games
  class ListsControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev.thegreatest.games"
      @list = lists(:games_list)
      @rc = ranking_configurations(:games_global)
    end

    # Index tests

    test "should get index with default ranking configuration" do
      get "/lists"
      assert_response :success
    end

    test "should get index with specific ranking configuration" do
      get "/rc/#{@rc.id}/lists"
      assert_response :success
    end

    test "should return 404 for non-existent ranking configuration on index" do
      get "/rc/99999/lists"
      assert_response :not_found
    end

    test "should return 404 for wrong ranking configuration type on index" do
      get "/rc/#{ranking_configurations(:books_global).id}/lists"
      assert_response :not_found
    end

    # Show tests

    test "should get show with list id" do
      get "/lists/#{@list.id}"
      assert_response :success
    end

    test "should get show with specific ranking configuration" do
      get "/rc/#{@rc.id}/lists/#{@list.id}"
      assert_response :success
    end

    test "should render show with list name" do
      get "/lists/#{@list.id}"
      assert_response :success
      assert_select "h1", text: @list.name
    end

    test "should return 404 for non-existent list" do
      get "/lists/99999"
      assert_response :not_found
    end

    test "should return 404 for non-existent ranking configuration on show" do
      get "/rc/99999/lists/#{@list.id}"
      assert_response :not_found
    end

    test "should return 404 for wrong ranking configuration type on show" do
      get "/rc/#{ranking_configurations(:books_global).id}/lists/#{@list.id}"
      assert_response :not_found
    end

    test "should handle page parameter on show" do
      get "/lists/#{@list.id}?page=1"
      assert_response :success
    end

    test "should handle page parameter beyond last page gracefully" do
      get "/lists/#{@list.id}?page=9999"
      assert_response :success
    end
  end
end
