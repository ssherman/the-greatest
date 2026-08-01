require "test_helper"

module Books
  class ListsControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev-new.thegreatestbooks.org"
      @rc = ranking_configurations(:books_global)
      @list = Books::List.create!(name: "Guardian 100", source: "The Guardian", status: :active)
      @ranked_list = RankedList.create!(list: @list, ranking_configuration: @rc, weight: 80)
    end

    test "index renders" do
      get "/lists"
      assert_response :success
    end

    test "index is indexable and cacheable by default" do
      get "/lists"

      assert @controller.view_assigns["indexable"]
      assert_match(/public/, response.headers["Cache-Control"])
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
      get "/lists?q=guardian"

      assert_response :success
      assert_not @controller.view_assigns["indexable"]
      assert_match(/no-store/, response.headers["Cache-Control"])
    end

    test "path-based pagination resolves the page" do
      seed_lists(60)

      get "/lists/page/2"

      assert_response :success
      assert_equal 2, @controller.view_assigns["pagy"].page
    end

    test "404s past the last page" do
      get "/lists/page/99"
      assert_response :not_found
    end

    test "renders an explicit ranking configuration" do
      get "/rc/#{@rc.id}/lists"
      assert_response :success
    end

    test "item counts are loaded for the page" do
      ListItem.create!(list: @list, listable: books_books(:war_and_peace), position: 1)

      get "/lists"

      assert_equal 1, @controller.view_assigns["item_counts"][@list.id]
    end

    test "index issues a bounded number of queries regardless of list count" do
      seed_lists(40)

      get "/lists"
      assert_response :success

      assert_queries_count(0) { get "/lists" }
    end

    private

    def seed_lists(count)
      count.times do |i|
        list = Books::List.create!(name: "Filler #{i}", status: :active)
        RankedList.create!(list: list, ranking_configuration: @rc, weight: i)
      end
    end
  end
end
