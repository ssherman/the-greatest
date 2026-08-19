require "test_helper"

module Books
  class GlobalCanonControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev-new.thegreatestbooks.org"
      @rc = ranking_configurations(:books_global)
      @fiction = categories(:books_fiction_genre)
      @next_rank = 0
      3.times { rank_fiction_book }
    end

    test "renders the canon" do
      get "/global-canon"

      assert_response :success
      assert_equal 3, @controller.view_assigns["result"].delivered
    end

    test "the bare path is indexable and carries a canonical" do
      Books::PublicIndexing.stubs(:enabled?).returns(true)

      get "/global-canon"

      assert_select "meta[name=robots][content=?]", "index, follow"
      assert_select "link[rel=canonical][href=?]", "http://dev-new.thegreatestbooks.org/global-canon"
    end

    test "a customised path is noindex and carries NO canonical" do
      # A canonical pointing away from a noindexed page risks propagating the
      # noindex to the target -- the rule Books::RankedItemsController states
      # for /rc/ URLs.
      Books::PublicIndexing.stubs(:enabled?).returns(true)

      get "/global-canon/total_books/250/nonfiction/40/max_per_country/2"

      assert_response :success
      assert_select "meta[name=robots][content=?]", "noindex, follow"
      assert_select "link[rel=canonical]", false
    end

    test "spelled-out defaults 301 to the bare path" do
      get "/global-canon/total_books/150/nonfiction/20/max_per_country/3"

      assert_redirected_to "/global-canon"
      assert_equal 301, response.status
    end

    test "a partial path 301s to the full form" do
      # The two shorter route shapes exist so a legacy URL resolves, but the
      # canonical is always the full three-segment form.
      get "/global-canon/total_books/250"

      assert_redirected_to "/global-canon/total_books/250/nonfiction/20/max_per_country/3"
      assert_equal 301, response.status
    end

    test "a query string 301s into the path form" do
      get "/global-canon?total_books=250"

      assert_redirected_to "/global-canon/total_books/250/nonfiction/20/max_per_country/3"
      assert_equal 301, response.status
    end

    test "the settings form 303s to the canonical path" do
      get "/global-canon/settings", params: {
        total_books: "250", nonfiction_percentage: "40", max_books_per_country: "2"
      }

      assert_redirected_to "/global-canon/total_books/250/nonfiction/40/max_per_country/2"
      assert_equal 303, response.status
    end

    test "an unroutable total 404s" do
      get "/global-canon/total_books/175"

      assert_response :not_found
    end

    test "an out-of-range country cap 404s" do
      get "/global-canon/total_books/250/nonfiction/40/max_per_country/11"

      assert_response :not_found
    end

    test "an invalid settings submission 404s rather than 500ing" do
      # #settings has no route-regex constraint the way #show does -- the
      # request reaches Books::GlobalCanonParams.call directly, which is the
      # only guard standing between a hand-edited query string and a 500 on a
      # public form target.
      get "/global-canon/settings", params: {total_books: "999"}

      assert_response :not_found
    end

    test "show carries public edge-cache headers" do
      get "/global-canon"

      assert_match "public", response.headers["Cache-Control"]
      assert_match "max-age=21600", response.headers["Cache-Control"]
    end

    test "the settings redirect is never cached" do
      get "/global-canon/settings", params: {total_books: "250"}

      assert_match "no-store", response.headers["Cache-Control"]
    end

    test "the short-list note names the binding constraint" do
      france = ::Books::Country.create!(name: "France", slug: "france", labels: [])
      3.times { rank_fiction_book(country: france) }

      get "/global-canon/total_books/250/nonfiction/0/max_per_country/1"

      assert_response :success
      assert_select "[data-testid=canon-short-list-note]", /of the 250 requested/
    end

    test "the short-list note explains an undersized pool without naming either cap" do
      # Setup's 3 books share no country (nil bucket) and have 3 distinct
      # authors, so neither cap ever binds against them -- delivered falls
      # short of requested purely because the candidate pool is smaller than
      # the request. blocked_by_country and blocked_by_author are both 0.
      get "/global-canon/total_books/250/nonfiction/0/max_per_country/10"

      assert_response :success
      note = css_select("[data-testid=canon-short-list-note]").first.text
      assert_match(/aren't enough ranked books to fill a canon this size/, note)
      assert_no_match(/per country/, note)
      assert_no_match(/per author/, note)
    end

    test "no note is shown when the canon is filled" do
      # 50 is the smallest selectable total, so the canon can only be "filled"
      # with at least 50 eligible books. Each gets its own country so the cap of
      # 10 never binds; setup's three country-less books share the nil bucket.
      seed_canon_books(50)

      get "/global-canon/total_books/50/nonfiction/0/max_per_country/10"

      assert_response :success
      assert_equal 50, @controller.view_assigns["result"].delivered
      assert_select "[data-testid=canon-short-list-note]", false
    end

    test "does not trap links in a turbo frame" do
      assert_no_frame_trapped_links "/global-canon"
    end

    test "renders the grid without an N+1" do
      get "/global-canon"  # warm the schema cache and any first-request lazy loads
      baseline = query_count_for("/global-canon")

      10.times { rank_fiction_book }

      # The grid preloads authors and cover images, so thirteen cards must cost
      # exactly what three did. `assert_queries_count` takes an ABSOLUTE number,
      # which churns on every unrelated query change; comparing the page to
      # itself at a different size is what actually detects an N+1. Note the
      # rank_fiction_book calls sit OUTSIDE both measurements -- inside, their
      # own INSERTs would be counted and the test would pass on anything.
      assert_equal baseline, query_count_for("/global-canon")
    end

    private

    def query_count_for(path)
      count = 0
      counter = ->(*, payload) { count += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get path }
      count
    end

    def seed_canon_books(count)
      count.times do |i|
        rank_fiction_book(country: ::Books::Country.create!(
          name: "Seed Country #{i}", slug: "seed-country-#{i}", labels: []
        ))
      end
    end

    def rank_fiction_book(country: nil)
      @next_rank += 1
      book = ::Books::Book.create!(title: "Canon Book #{@next_rank}")
      ::Books::BookCountry.create!(book: book, country: country) if country
      ::Books::BookAuthor.create!(
        book: book, author: ::Books::Author.create!(name: "Author #{@next_rank}"),
        position: 1, role: :author
      )
      ::CategoryItem.create!(category: @fiction, item: book)
      ::RankedItem.create!(item: book, ranking_configuration: @rc, rank: @next_rank, score: 10_000 - @next_rank)
      book
    end
  end
end
