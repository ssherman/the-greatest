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

    test "should return 404 for a page parameter beyond the last page" do
      get "/lists/#{@list.id}?page=9999"
      assert_response :not_found
    end

    test "list show pagination is path-based" do
      list = lists(:games_list)

      get "/lists/#{list.id}"

      assert_equal "/lists/#{list.id}/page/2", @controller.view_assigns["pagy"].page_url(2)
    end

    test "list show resolves a path-based page" do
      list = lists(:games_list)
      seed_list_items(list, 150)

      get "/lists/#{list.id}/page/2"

      assert_response :success
      assert_equal 2, @controller.view_assigns["pagy"].page
    end

    private

    # Bulk-inserts filler games + list items so tests can reach page 2+
    # against the controller's limit of 100. insert_all skips callbacks
    # deliberately (avoids search indexing per row).
    def seed_list_items(list, count)
      now = Time.current
      rows = Array.new(count) do |i|
        {title: "Filler Game #{i}", slug: "filler-game-#{list.id}-#{i}", created_at: now, updated_at: now}
      end
      ids = Games::Game.insert_all(rows, returning: :id).rows.flatten

      start_position = list.list_items.maximum(:position).to_i + 1
      ListItem.insert_all(
        ids.each_with_index.map do |id, i|
          {list_id: list.id, listable_id: id, listable_type: "Games::Game",
           position: start_position + i, created_at: now, updated_at: now}
        end
      )
    end
  end
end
