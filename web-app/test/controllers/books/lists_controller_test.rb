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

      ActiveRecord::Base.connection.clear_query_cache
      assert_queries_count(4) { get "/lists" }
    end

    test "show renders an active list" do
      get "/lists/#{@list.id}"
      assert_response :success
    end

    test "show 404s for a non-active list" do
      @list.update!(status: :unapproved)

      get "/lists/#{@list.id}"

      assert_response :not_found
    end

    test "show 404s for an unknown id" do
      get "/lists/999999"
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

    test "show paginates its items" do
      seed_items(120)

      get "/lists/#{@list.id}/page/2"

      assert_response :success
      assert_equal 2, @controller.view_assigns["pagy"].page
    end

    test "show 404s past the last item page" do
      get "/lists/#{@list.id}/page/99"
      assert_response :not_found
    end

    test "show loads ranks for the books on the page" do
      book = books_books(:war_and_peace)
      ListItem.create!(list: @list, listable: book, position: 1)
      RankedItem.create!(item: book, ranking_configuration: @rc, rank: 7, score: 50)

      get "/lists/#{@list.id}"

      assert_equal 7, @controller.view_assigns["ranks"][book.id]
    end

    test "show survives a list item whose listable no longer exists" do
      ListItem.create!(list: @list, listable_type: "Books::Book", listable_id: 999_999_999, position: 1)

      get "/lists/#{@list.id}"

      assert_response :success
    end

    test "show issues a bounded number of queries and preloads covers" do
      book = books_books(:war_and_peace)
      ListItem.create!(list: @list, listable: book, position: 1)
      seed_items(20)

      covered_books = [book] + Books::Book.where(title: (0...5).map { |i| "Item Book #{i}" }).to_a
      covered_books.each do |covered_book|
        image = Image.new(parent: covered_book, primary: true)
        image.file.attach(io: StringIO.new("fake image data"), filename: "cover.jpg", content_type: "image/jpeg")
        image.save!
      end

      get "/lists/#{@list.id}"
      assert_response :success

      ActiveRecord::Base.connection.clear_query_cache
      assert_queries_count(12) { get "/lists/#{@list.id}" }
    end

    test "legacy sorted-by weight redirects to the canonical index" do
      get "/lists/sorted-by/weight"
      assert_redirected_to "/lists"
      assert_response :moved_permanently
    end

    test "legacy sorted-by created_at redirects to the newest sort" do
      get "/lists/sorted-by/created_at"
      assert_redirected_to "/lists?sort=newest"
      assert_response :moved_permanently
    end

    test "legacy paged sorted-by redirects to the canonical index" do
      get "/lists/sorted-by/weight/page/3"
      assert_redirected_to "/lists"
      assert_response :moved_permanently
    end

    test "legacy collection pages redirect to the canonical index" do
      ["/lists/search_results", "/lists/condensed", "/lists/help",
        "/lists/pending_lists", "/lists/specialized_edit"].each do |path|
        get path
        assert_redirected_to "/lists"
        assert_response :moved_permanently
      end
    end

    test "legacy view-prefixed list detail redirects to the plain path" do
      get "/v/grid/lists/#{@list.id}"
      assert_redirected_to "/lists/#{@list.id}"
      assert_response :moved_permanently
    end

    test "legacy view-prefixed index redirects to the canonical index" do
      get "/v/table/lists"
      assert_redirected_to "/lists"
      assert_response :moved_permanently
    end

    private

    def seed_lists(count)
      count.times do |i|
        list = Books::List.create!(name: "Filler #{i}", status: :active)
        RankedList.create!(list: list, ranking_configuration: @rc, weight: i)
      end
    end

    def seed_items(count)
      now = Time.current
      rows = Array.new(count) { |i| {title: "Item Book #{i}", slug: "item-book-#{i}", created_at: now, updated_at: now} }
      ids = Books::Book.insert_all(rows, returning: :id).rows.flatten
      ListItem.insert_all(
        ids.each_with_index.map do |id, i|
          {list_id: @list.id, listable_id: id, listable_type: "Books::Book",
           position: i + 1, created_at: now, updated_at: now}
        end
      )
    end
  end
end
