require "test_helper"

module Books
  class BooksControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev-new.thegreatestbooks.org"
      @rc = ranking_configurations(:books_global)
      @book = books_books(:war_and_peace)
    end

    test "renders a book by slug" do
      get "/book/#{@book.slug}"
      assert_response :success
    end

    test "404s for an unknown slug" do
      get "/book/no-such-book"
      assert_response :not_found
    end

    test "does not fall back to a primary key lookup" do
      get "/book/#{@book.id}"
      assert_response :not_found
    end

    test "marks a ranked book indexable" do
      RankedItem.create!(item: @book, ranking_configuration: @rc, rank: 1, score: 100)

      get "/book/#{@book.slug}"

      assert @controller.view_assigns["indexable"]
    end

    test "marks an unranked book not indexable" do
      get "/book/#{@book.slug}"

      refute @controller.view_assigns["indexable"]
    end

    test "renders a book whose slug is purely numeric" do
      numeric = Books::Book.create!(title: "Nineteen Eighty-Four Vol 1", slug: "1984")

      get "/book/1984"

      assert_response :success
      assert_equal numeric.id, @controller.view_assigns["book"].id
    end

    test "sanitizes description content before rendering" do
      Description.create!(
        describable: @book,
        kind: :summary,
        locale: "en",
        source: :manual,
        content: "Nice book. <img src=x onerror=alert(1)>"
      )

      get "/book/#{@book.slug}"

      assert_response :success
      refute_includes response.body, "onerror"
    end
    test "treats a book with a null rank as unranked instead of raising" do
      item = RankedItem.new(item: @book, ranking_configuration: @rc, rank: nil, score: 10)
      item.save!(validate: false)

      get "/book/#{@book.slug}"

      assert_response :success
      assert_nil @controller.view_assigns["ranked_item"]
      refute @controller.view_assigns["indexable"]
    end

    test "list names on the book page link to the list" do
      book = books_books(:war_and_peace)
      list = Books::List.create!(name: "Guardian 100", status: :active)
      RankedList.create!(list: list, ranking_configuration: @rc, weight: 50)
      ListItem.create!(list: list, listable: book, position: 1)

      get "/book/#{book.slug}"

      assert_response :success
      assert_select "a[href=?]", "/lists/#{list.id}"
    end

    test "assigns the review summary and only the written reviews" do
      get "/book/#{@book.slug}"

      assert_response :success
      assert_equal review_summaries(:war_and_peace), @controller.view_assigns["review_summary"]
      assert_equal 2, @controller.view_assigns["reviews"].size
      assert @controller.view_assigns["reviews"].all? { |review| review.body.present? }
    end

    test "orders the reviews newest first" do
      older = Review.create!(user: users(:password_user), reviewable: @book, rating: 2, body: "<p>Older.</p>")
      older.update_columns(created_at: 5.years.ago)

      get "/book/#{@book.slug}"

      assert_equal older.id, @controller.view_assigns["reviews"].last.id
    end

    test "renders the summary line and the reviews card for a rated book" do
      get "/book/#{@book.slug}"

      assert_select "[data-testid='review-summary-line']"
      assert_select "#ratings-reviews"
      assert_select "[data-testid='review']", 2
    end

    test "renders the card without a review list for a book rated but not reviewed" do
      book = books_books(:crime_and_punishment)

      get "/book/#{book.slug}"

      assert_select "#ratings-reviews"
      assert_select "[data-testid='review']", 0
    end

    test "renders no rating surface at all for an unrated book" do
      book = books_books(:got)

      get "/book/#{book.slug}"

      assert_response :success
      assert_select "[data-testid='review-summary-line']", 0
      assert_select "#ratings-reviews", 0
    end

    test "renders review bodies as markup rather than escaping them" do
      get "/book/#{@book.slug}"

      assert_select "[data-testid='review-body'] p", text: "Worth every one of its twelve hundred pages."
    end

    # The N+1 guard. Written as a comparison rather than a fixed count so that an
    # unrelated query added to #show does not fail it -- what must hold is that the
    # number of queries is independent of the number of reviews rendered.
    test "renders any number of reviews with the same number of queries" do
      book = books_books(:crime_and_punishment)
      Review.create!(user: users(:editor_user), reviewable: book, rating: 5, body: "<p>One.</p>")
      baseline = count_queries { get "/book/#{book.slug}" }

      Review.create!(user: users(:admin_user), reviewable: book, rating: 4, body: "<p>Two.</p>")
      Review.create!(user: users(:password_user), reviewable: book, rating: 3, body: "<p>Three.</p>")
      with_more = count_queries { get "/book/#{book.slug}" }

      # Without this, the comparison above passes trivially if CardComponent#render?
      # ever returns false or the card is dropped from the view -- zero queries would
      # equal zero queries either way. Pin that the reviews actually rendered so the
      # query-count comparison is guarding something real.
      assert_select "[data-testid='review']", 3

      assert_equal baseline, with_more,
        "rendering reviews must not issue a query per review"
    end

    # Deliberately not declared `private`. Minitest only collects public `test_`
    # methods, so a `private` keyword here would silently stop every test defined
    # after it in the file from running.
    def count_queries
      count = 0
      counter = lambda do |_name, _start, _finish, _id, payload|
        next if payload[:name] == "SCHEMA"
        next if payload[:sql].start_with?("BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT", "RELEASE")

        count += 1
      end

      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
      count
    end
  end
end
