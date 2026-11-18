require "test_helper"

module Admin
  module Books
    class PublisherTitlesControllerTest < ActionDispatch::IntegrationTest
      include SqlCapture

      setup do
        host! Rails.application.config.domains[:books]
        @admin = users(:admin_user)
        @ready = books_publisher_titles(:ready_title)
        @held = books_publisher_titles(:held_incomplete_title)
      end

      def listed_ids
        css_select("[data-testid=title-row]").map { |row| row["data-title-id"].to_i }
      end

      test "the list links to each title's detail page" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_publisher_titles_path
        assert_response :success
        assert_select "a[href=?]", admin_books_publisher_title_path(@ready)
        assert_select "a[href=?]", admin_books_publisher_title_path(@held)
      end

      test "the default order is upcoming first, undated last" do
        late = ::Books::PublisherTitle.create!(source: "hachette_us", title: "Late", status: :ready, on_sale_on: Date.new(2028, 1, 1))
        early = ::Books::PublisherTitle.create!(source: "hachette_us", title: "Early", status: :ready, on_sale_on: Date.new(2026, 1, 1))
        undated = ::Books::PublisherTitle.create!(source: "hachette_us", title: "Undated", status: :ready)
        sign_in_as(@admin, stub_auth: true)

        get admin_books_publisher_titles_path
        assert_response :success

        hrefs = css_select("a[href]").map { |a| a["href"] }
        positions = [early, late, undated].map { |t| hrefs.index(admin_books_publisher_title_path(t)) }
        assert_equal 3, positions.compact.size
        assert_equal positions.sort, positions
      end

      test "filters by source, status and hold reason narrow the list" do
        sign_in_as(@admin, stub_auth: true)

        get admin_books_publisher_titles_path(source: "hachette_us")
        assert_includes listed_ids, @ready.id
        assert_not_includes listed_ids, @held.id

        get admin_books_publisher_titles_path(status: "held")
        assert_includes listed_ids, @held.id
        assert_not_includes listed_ids, @ready.id

        get admin_books_publisher_titles_path(hold_reason: "incomplete")
        assert_equal [@held.id], listed_ids
      end

      test "an unknown filter value is ignored, not an error" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_publisher_titles_path(source: "nope", status: "nope", hold_reason: "nope")
        assert_response :success
        assert_includes listed_ids, @ready.id
        assert_includes listed_ids, @held.id
      end

      test "titles are paginated" do
        51.times do |i|
          ::Books::PublisherTitle.create!(source: "page_house", title: "Paged #{i}", isbn13s: [format("97800000%05d", i)])
        end
        sign_in_as(@admin, stub_auth: true)
        get admin_books_publisher_titles_path(source: "page_house")
        assert_response :success
        assert_equal 50, listed_ids.size
        assert_select "a[href*='page=2']"

        get admin_books_publisher_titles_path(source: "page_house", page: 2)
        assert_equal 1, listed_ids.size
      end

      test "the detail page renders for a ready and for a held title, and 404s for an unknown id" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_publisher_title_path(@ready)
        assert_response :success
        assert_select "a[href=?][rel='noopener noreferrer'][target=_blank]", books_publisher_listings(:read_listing).url
        get admin_books_publisher_title_path(@held)
        assert_response :success
        get admin_books_publisher_title_path(id: 0)
        assert_response :not_found
      end

      test "the detail page shows the description as text, never as markup, and only an https cover" do
        @ready.update!(description: "<script>alert(1)</script> plain", cover_url: "http://insecure.example/c.jpg")
        sign_in_as(@admin, stub_auth: true)
        get admin_books_publisher_title_path(@ready)
        assert_response :success
        assert_select "script", text: /alert/, count: 0
        assert_select "img[src='http://insecure.example/c.jpg']", count: 0
        assert_includes response.body, "&lt;script&gt;alert(1)&lt;/script&gt;"

        @ready.update!(cover_url: "https://images.example/c.jpg")
        get admin_books_publisher_title_path(@ready)
        assert_select "img[src='https://images.example/c.jpg']"
      end

      test "the list never shows descriptions" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_publisher_titles_path
        assert_not_includes response.body, @ready.description
      end

      test "the index does not load listings per row" do
        sign_in_as(@admin, stub_auth: true)
        sql = capture_sql { get admin_books_publisher_titles_path }
        assert_response :success
        assert_equal 0, sql.count { |q| q.include?("books_publisher_listings") }
      end

      test "a signed-out visitor and a regular user are redirected" do
        get admin_books_publisher_titles_path
        assert_redirected_to books_root_path
        sign_in_as(users(:regular_user), stub_auth: true)
        get admin_books_publisher_title_path(@ready)
        assert_redirected_to books_root_path
      end

      test "there are no write routes" do
        %i[new_admin_books_publisher_title_path edit_admin_books_publisher_title_path].each do |helper|
          assert_not respond_to?(helper), "#{helper} should not exist"
        end
        sign_in_as(@admin, stub_auth: true)
        delete "/admin/publisher_titles/#{@ready.id}"
        assert_response :not_found
        patch "/admin/publisher_titles/#{@ready.id}", params: {books_publisher_title: {title: "X"}}
        assert_response :not_found
        post "/admin/publisher_titles"
        assert_response :not_found
        assert_equal "The Example Garden", @ready.reload.title
      end
    end
  end
end
