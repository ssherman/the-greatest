require "test_helper"

module Games
  class ListsControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev.thegreatest.games"
      @rc = ranking_configurations(:games_global)
      @list = Games::List.create!(name: "Games Test List", source: "Games Source", status: :active)
      @ranked_list = RankedList.create!(list: @list, ranking_configuration: @rc, weight: 8)
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
      get "/lists/#{@list.id}"

      assert_equal "/lists/#{@list.id}/page/2", @controller.view_assigns["pagy"].page_url(2)
    end

    test "list show resolves a path-based page" do
      seed_list_items(@list, 150)

      get "/lists/#{@list.id}/page/2"

      assert_response :success
      assert_equal 2, @controller.view_assigns["pagy"].page
    end

    test "show 404s for a non-active list" do
      @list.update!(status: :unapproved)

      get "/lists/#{@list.id}"

      assert_response :not_found
    end

    test "show is indexable when the list is in the ranking configuration" do
      get "/lists/#{@list.id}"

      assert @controller.view_assigns["indexable"]
    end

    test "show is not indexable when the list is outside the ranking configuration" do
      @ranked_list.destroy!

      get "/lists/#{@list.id}"

      assert_response :success
      assert_not @controller.view_assigns["indexable"]
    end

    test "page one of a list redirects to the canonical path" do
      get "/lists/#{@list.id}/page/1"

      assert_redirected_to "/lists/#{@list.id}"
      assert_response :moved_permanently
    end

    test "show survives a list item whose listable no longer exists" do
      ListItem.create!(list: @list, listable_type: "Games::Game", listable_id: 999_999_999, position: 1)

      get "/lists/#{@list.id}"

      assert_response :success
    end

    test "index accepts the newest sort" do
      get "/lists?sort=newest"

      assert_response :success
      assert_equal "newest", @controller.view_assigns["sort"]
    end

    test "index falls back to weight for an unknown sort" do
      get "/lists?sort=bogus"

      assert_response :success
      assert_equal "weight", @controller.view_assigns["sort"]
    end

    test "search suppresses indexing and edge caching" do
      get "/lists?q=games"

      assert_response :success
      assert_not @controller.view_assigns["indexable"]
      assert_match(/no-store/, response.headers["Cache-Control"])
    end

    test "index is indexable and cacheable by default" do
      get "/lists"

      assert @controller.view_assigns["indexable"]
      assert_match(/public/, response.headers["Cache-Control"])
    end

    test "a nested q param does not blow up" do
      get "/lists?q[a]=1"

      assert_response :success
      assert_nil @controller.view_assigns["query"]
    end

    test "index pagination is path-based" do
      get "/lists"

      assert_equal "/lists/page/2", @controller.view_assigns["pagy"].page_url(2)
    end

    test "index resolves a path-based page" do
      seed_lists(60)

      get "/lists/page/2"

      assert_response :success
      assert_equal 2, @controller.view_assigns["pagy"].page
    end

    test "index 404s past the last page" do
      get "/lists/page/99"
      assert_response :not_found
    end

    test "page one of the index redirects to the canonical path" do
      get "/lists/page/1"
      assert_redirected_to "/lists"
      assert_response :moved_permanently
    end

    test "index issues a bounded number of queries regardless of list count" do
      seed_lists(40)

      get "/lists"
      assert_response :success

      ActiveRecord::Base.connection.clear_query_cache
      assert_queries_count(4) { get "/lists" }
    end

    test "show issues a bounded number of queries and preloads covers" do
      game = games_games(:breath_of_the_wild)
      ListItem.create!(list: @list, listable: game, position: 1)
      seed_list_items(@list, 20)

      covered = [game] + Games::Game.where(title: (0...5).map { |i| "Filler Game #{i}" }).to_a
      covered.each do |covered_game|
        image = Image.new(parent: covered_game, primary: true)
        image.file.attach(io: StringIO.new("fake image data"), filename: "cover.jpg", content_type: "image/jpeg")
        image.save!
      end

      get "/lists/#{@list.id}"
      assert_response :success

      ActiveRecord::Base.connection.clear_query_cache
      assert_queries_count(15) { get "/lists/#{@list.id}" }
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

    def seed_lists(count)
      count.times do |i|
        list = Games::List.create!(name: "Filler List #{i}", status: :active)
        RankedList.create!(list: list, ranking_configuration: @rc, weight: i)
      end
    end
  end
end
