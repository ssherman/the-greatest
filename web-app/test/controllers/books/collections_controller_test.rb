require "test_helper"

module Books
  class CollectionsControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev-new.thegreatestbooks.org"
      @rc = ranking_configurations(:books_global)
      RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @rc, rank: 1, score: 100)
      RankedItem.create!(item: books_books(:of_mice_and_men), ranking_configuration: @rc, rank: 2, score: 90)
    end

    test "every registered collection renders" do
      Collections::Registry.slugs(:books).each do |slug|
        get "/#{slug}"
        assert_response :success, "/#{slug} did not render"
      end
    end

    test "western shows only books from western countries" do
      get "/western"

      ids = @controller.view_assigns["ranked_books"].map(&:item_id)
      assert_includes ids, books_books(:war_and_peace).id
      refute_includes ids, books_books(:of_mice_and_men).id
    end

    test "africa shows books from african countries" do
      books_countries(:algerian).update!(labels: ["african"])
      Books::BookCountry.create!(book: books_books(:of_mice_and_men), country: books_countries(:algerian))

      get "/africa"

      assert_equal [books_books(:of_mice_and_men).id],
        @controller.view_assigns["ranked_books"].map(&:item_id)
    end

    test "a collection slug in the query string does not scope the homepage" do
      get "/?collection=africa"

      assert_response :success
      assert_equal "The Greatest Books of All Time", @controller.view_assigns["page_title"]
      ids = @controller.view_assigns["ranked_books"].map(&:item_id)
      assert_includes ids, books_books(:of_mice_and_men).id
    end

    test "women shows books with any female author" do
      books_authors(:garnett).update!(gender: :female)
      Books::BookAuthor.create!(book: books_books(:war_and_peace),
        author: books_authors(:garnett), position: 2, role: 0)

      get "/women"

      assert_equal [books_books(:war_and_peace).id],
        @controller.view_assigns["ranked_books"].map(&:item_id)
    end

    test "the page title uses the collection prefix" do
      get "/africa"
      assert_equal "The Greatest African Books of All Time", @controller.view_assigns["page_title"]
    end

    test "a country_id query string does not scope a collection page" do
      books_countries(:algerian).update!(labels: ["african"])
      Books::BookCountry.create!(book: books_books(:of_mice_and_men), country: books_countries(:algerian))

      # french is western, not african, and of_mice_and_men has no french
      # link -- if country_id leaked into the collection query, this would
      # filter of_mice_and_men out and leave the collection empty.
      get "/africa?country_id=french"

      assert_response :success
      assert_equal "/africa", @controller.view_assigns["canonical_path"]
      assert_equal [books_books(:of_mice_and_men).id],
        @controller.view_assigns["ranked_books"].map(&:item_id)
    end

    test "the canonical path is the bare collection" do
      get "/africa"
      assert_equal "/africa", @controller.view_assigns["canonical_path"]
    end

    test "the site hero is suppressed on a collection page" do
      get "/africa"
      refute @controller.view_assigns["show_hero"]
    end

    test "an rc-prefixed collection gets no canonical" do
      get "/rc/#{@rc.id}/africa"
      assert_response :success
      assert_nil @controller.view_assigns["canonical_path"]
    end

    test "a collection paginates on a path" do
      # 100 per page, so page 2 needs more than 100 ranked western books.
      120.times do |i|
        book = Books::Book.create!(title: "Western Filler #{i}", first_published_year: 1950)
        Books::BookCountry.create!(book: book, country: books_countries(:french))
        RankedItem.create!(item: book, ranking_configuration: @rc, rank: 100 + i, score: 10)
      end

      get "/western/page/2"

      assert_response :success
      assert_equal 2, @controller.view_assigns["pagy"].page
    end

    test "a page past the last raises not found" do
      get "/western/page/99"
      assert_response :not_found
    end

    test "the-greatest-books under a collection redirects to the bare slug" do
      get "/africa/the-greatest-books"
      assert_redirected_to "/africa"
      assert_response :moved_permanently
    end

    test "the legacy the-greatest/books form redirects to the bare slug" do
      get "/africa/the-greatest/books"
      assert_redirected_to "/africa"
      assert_response :moved_permanently
    end

    test "the legacy the-greatest/books/page form redirects preserving the page number" do
      get "/africa/the-greatest/books/page/3"
      assert_redirected_to "/africa/page/3"
      assert_response :moved_permanently
    end

    test "a legacy view-type url redirects to the bare slug" do
      get "/v/grid/africa"
      assert_redirected_to "/africa"
      assert_response :moved_permanently
    end

    test "a collection index does not N+1 over its books" do
      # A bound checked against the default setup's single rendered book can't
      # tell a fixed preload from a per-row N+1 -- both look like "8 queries"
      # at n=1. Render at the scale the pagination test already establishes
      # (100+ books per page), each with its own distinct author, so a query
      # that scales with the row count would actually show up here.
      120.times do |i|
        book = Books::Book.create!(title: "Western Filler #{i}", first_published_year: 1950)
        author = Books::Author.create!(name: "Filler Author #{i}", slug: "filler-author-#{i}", kind: 0)
        Books::BookCountry.create!(book: book, country: books_countries(:french))
        Books::BookAuthor.create!(book: book, author: author, position: 1, role: 0)
        RankedItem.create!(item: book, ranking_configuration: @rc, rank: 100 + i, score: 10)
      end

      assert_queries_count(8) { get "/western" }
    end

    test "collection pages have no turbo-frame trapped links" do
      assert_no_frame_trapped_links "/africa"
    end

    test "the nav lists every registered collection" do
      get "/"

      # The nav's <li> block is rendered from a shared partial in TWO places
      # (the narrow-screen dropdown and the wide-screen bar), so a correctly
      # rendered page has each link exactly twice. Asserting only minimum: 1
      # would pass even if one of the two copies were missing the link.
      Collections::Registry.for(:books).each do |collection|
        assert_select "a[href=?]", "/#{collection.slug}", {count: 2},
          "nav is missing a link to /#{collection.slug} in one or both copies"
      end
      assert_select "a[href=?]", "/the-greatest-books/since/2000", count: 2
      assert_select "a[href=?]", "/lists/463", count: 2
    end
  end
end
