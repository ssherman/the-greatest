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

    test "renders the rating widget for every visitor" do
      get "/book/#{@book.slug}"

      assert_select "#review_widget [data-controller='reviews--widget']"
    end

    test "renders the widget with no user-specific state for an anonymous visitor" do
      get "/book/#{@book.slug}"

      # Mirrors the component's own pinned neutral-fill selector
      # (test/components/reviews/widget_component_test.rb) -- the stars span is
      # always present (Task 6), so "no user-specific state" now means a zero
      # fill rather than an absent element.
      assert_select "#review_widget [data-testid='review-widget-stars'] [data-testid='stars-fill'][style='width: 0.0%']"
    end

    # The very first rating on an unrated book has to have something to replace.
    test "renders an empty summary-line target for an unrated book" do
      get "/book/#{books_books(:got).slug}"

      assert_response :success
      assert_select "#review_summary_line"
    end

    test "renders the summary-line target for a rated book" do
      get "/book/#{@book.slug}"

      assert_select "#review_summary_line [data-testid='review-summary-line']"
    end

    # --- Author, category and country links, and the details card ---

    test "the author name links to the author page" do
      get "/book/#{@book.slug}"

      assert_select "a[href=?]", "/author/leo-tolstoy", text: "Leo Tolstoy"
    end

    test "the author link carries the ranking configuration prefix" do
      rc = ranking_configurations(:books_inherited)

      get "/rc/#{rc.id}/book/#{@book.slug}"

      assert_select "a[href=?]", "/rc/#{rc.id}/author/leo-tolstoy"
    end

    test "each category links to that category's filtered list" do
      get "/book/#{@book.slug}"

      assert_select "a[href=?]", "/the-greatest/classics/books", text: "Classics"
      assert_select "a[href=?]", "/the-greatest/novels/books", text: "Novels"
    end

    # A location category routes through the same grammar as a genre -- the filter
    # params resolve any active Books::Category by slug, with no type restriction.
    test "a location category links through the same filter grammar as a genre" do
      CategoryItem.create!(category: categories(:books_france_location), item: @book)

      get "/book/#{@book.slug}"

      assert_select "a[href=?]", "/the-greatest/france/books", text: "France"
    end

    test "category links carry the ranking configuration prefix" do
      rc = ranking_configurations(:books_inherited)

      get "/rc/#{rc.id}/book/#{@book.slug}"

      assert_select "a[href=?]", "/rc/#{rc.id}/the-greatest/novels/books"
    end

    test "groups the categories genre, then subject, then location" do
      CategoryItem.create!(category: categories(:books_france_location), item: @book)
      CategoryItem.create!(category: categories(:books_politics_subject), item: @book)

      get "/book/#{@book.slug}"

      assert_equal ["Genres", "Subjects", "Locations"],
        css_select("[data-testid='category-group'] h3").map { |heading| heading.text.strip }
    end

    test "sorts the categories by name within a group" do
      # Created last, so its id sorts after both fixture genres. The two fixtures
      # already come back from the database in name order, so without a row whose
      # id order and name order disagree this assertion passes whether or not the
      # sort exists.
      adventure = Books::Category.create!(name: "Adventure", category_type: :genre)
      CategoryItem.create!(category: adventure, item: @book)

      get "/book/#{@book.slug}"

      assert_equal ["Adventure", "Classics", "Novels"],
        css_select("[data-testid='category-group'] a").map { |link| link.text.strip }
    end

    test "renders the details a book has values for" do
      # page_range drives book_length through the model's derive callback, so this
      # sets both.
      @book.update!(page_range: "1200-1300")

      get "/book/#{@book.slug}"

      assert_equal "1869", detail_value("published")
      assert_equal "French", detail_value("origin")
      assert_equal "Very Long", detail_value("length")
      assert_equal "1200-1300", detail_value("pages")
      assert_equal "Russian", detail_value("original-language")
      assert_equal "Voyna i mir", detail_value("alternate-titles")
    end

    test "the origin links to the country-filtered list" do
      get "/book/#{@book.slug}"

      assert_select "[data-testid='detail-origin'] a[href=?]",
        "/the-greatest-books/written-by/french/authors", text: "French"
    end

    # Books::Country.filterable hides the Unknown row from /countries, so linking it
    # here would route readers into a page the site otherwise conceals. 27% of the
    # corpus sits on that row.
    test "omits an unknown origin rather than linking it" do
      book = books_books(:got)
      book.book_countries.destroy_all
      Books::BookCountry.create!(book: book, country: books_countries(:unknown))

      get "/book/#{book.slug}"

      assert_response :success
      assert_select "[data-testid='detail-origin']", 0
    end

    test "omits a detail row the book has no value for" do
      get "/book/#{@book.slug}"

      assert_select "[data-testid='detail-published']", 1
      assert_select "[data-testid='detail-pages']", 0
      assert_select "[data-testid='detail-length']", 0
    end

    test "renders no details card at all for a book with no metadata" do
      book = Books::Book.create!(title: "A Book With Nothing Known About It")

      get "/book/#{book.slug}"

      assert_response :success
      assert_select "[data-testid='book-details']", 0
    end

    test "shows every alternate title inline when there are five or fewer" do
      @book.update!(alternate_titles: ["Voyna i mir", "La Guerre et la Paix"])

      get "/book/#{@book.slug}"

      assert_equal ["La Guerre et la Paix", "Voyna i mir"],
        css_select("[data-testid='alternate-titles-visible'] li").map { |item| item.text.strip }
      assert_select "[data-testid='alternate-titles-rest']", 0
    end

    test "hides alternate titles past the fifth behind an expander" do
      @book.update!(alternate_titles: %w[Golf Foxtrot Echo Delta Charlie Bravo Alpha])

      get "/book/#{@book.slug}"

      assert_equal %w[Alpha Bravo Charlie Delta Echo],
        css_select("[data-testid='alternate-titles-visible'] li").map { |item| item.text.strip }
      assert_equal %w[Foxtrot Golf],
        css_select("[data-testid='alternate-titles-rest'] li").map { |item| item.text.strip }
    end

    # Deliberately not declared `private`, for the same reason count_queries below
    # is not.
    def detail_value(key)
      css_select("[data-testid='detail-#{key}'] dd").map { |value| value.text.strip }.first
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
