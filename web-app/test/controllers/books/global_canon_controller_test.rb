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

    test "a recognized query key resolving to the default settings still 301s" do
      # Comparing the computed canonical path against request.path alone
      # misses this: request.path excludes the query string, so
      # ?total_books=150 (150 is the default) computes the same bare canonical
      # path the request already appears to be at, and the redirect would be
      # skipped -- serving a publicly-cacheable 200 under a URL that mints its
      # own Cloudflare cache entry. The QUERY_FORM_KEYS check exists precisely
      # to force this redirect anyway.
      get "/global-canon?total_books=150"

      assert_redirected_to "/global-canon"
      assert_equal 301, response.status
    end

    test "the redirect target for a default-resolving query is terminal" do
      # Proves the fix doesn't loop: following the 301 must land on a plain
      # 200, not another redirect.
      get "/global-canon?total_books=150"
      assert_redirected_to "/global-canon"

      get "/global-canon"

      assert_response :success
    end

    test "an unrecognized query parameter does not trigger a redirect" do
      # utm_source, fbclid and friends must survive -- redirecting those away
      # destroys campaign attribution. Mirrors
      # Books::BrowseController's equivalent test.
      get "/global-canon", params: {utm_source: "newsletter"}

      assert_response :success
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

    test "the short-list note does not offer the country lever when raising it would not help" do
      # Two NON-FICTION books share both a country and an author, and the
      # request is 100% non-fiction so the fiction pass never runs -- setup's
      # 3 fiction books are never scanned and cannot contaminate the
      # attribution. Under a country cap of 1, the second book fails BOTH
      # checks: its country is full AND its author is already used. If it
      # were still attributed to blocked_by_country (the pre-fix behaviour),
      # this note would incorrectly tell the visitor raising the country cap
      # gets them more books -- it would not, since the author check would
      # still reject the very same book.
      nonfiction = categories(:books_nonfiction_genre)
      shared_country = ::Books::Country.create!(name: "Shared Country", slug: "shared-country", labels: [])
      shared_author = ::Books::Author.create!(name: "Shared Author")
      2.times do
        @next_rank += 1
        book = ::Books::Book.create!(title: "Canon NF Book #{@next_rank}")
        ::Books::BookCountry.create!(book: book, country: shared_country)
        ::Books::BookAuthor.create!(book: book, author: shared_author, position: 1, role: :author)
        ::CategoryItem.create!(category: nonfiction, item: book)
        ::RankedItem.create!(item: book, ranking_configuration: @rc, rank: @next_rank, score: 10_000 - @next_rank)
      end

      get "/global-canon/total_books/50/nonfiction/100/max_per_country/1"

      assert_response :success
      note = css_select("[data-testid=canon-short-list-note]").first.text
      assert_no_match(/per country/, note)
      assert_match(/one book per author/, note)
    end

    test "the short-list note offers the country lever even when author-blocked books outnumber it" do
      # blocked_by_country ends up 1 (one country-only rejection) and
      # blocked_by_author ends up 2 (two author-only rejections) -- fewer,
      # but each of the 1 is a genuine "raise the cap and get one more."
      # The OLD branch condition (blocked_by_country >= blocked_by_author)
      # would suppress the country message here since 1 < 2, even though
      # raising the country cap demonstrably would help. The new `.positive?`
      # check is what the task calls "simpler and provably correct": ANY
      # positive blocked_by_country is actionable under the new attribution
      # semantics, regardless of how it compares to blocked_by_author.
      nonfiction = categories(:books_nonfiction_genre)
      country_a = ::Books::Country.create!(name: "Country A", slug: "country-a", labels: [])
      2.times do |i|
        @next_rank += 1
        book = ::Books::Book.create!(title: "Canon NF Book #{@next_rank}")
        ::Books::BookCountry.create!(book: book, country: country_a)
        ::Books::BookAuthor.create!(book: book, author: ::Books::Author.create!(name: "NF Author #{@next_rank}"), position: 1, role: :author)
        ::CategoryItem.create!(category: nonfiction, item: book)
        ::RankedItem.create!(item: book, ranking_configuration: @rc, rank: @next_rank, score: 10_000 - @next_rank)
      end

      shared_author = ::Books::Author.create!(name: "Popular NF Author")
      3.times do |i|
        @next_rank += 1
        book = ::Books::Book.create!(title: "Canon NF Author Book #{@next_rank}")
        ::Books::BookCountry.create!(book: book, country: ::Books::Country.create!(name: "Solo Country #{i}", slug: "solo-country-#{i}", labels: []))
        ::Books::BookAuthor.create!(book: book, author: shared_author, position: 1, role: :author)
        ::CategoryItem.create!(category: nonfiction, item: book)
        ::RankedItem.create!(item: book, ranking_configuration: @rc, rank: @next_rank, score: 10_000 - @next_rank)
      end

      get "/global-canon/total_books/50/nonfiction/100/max_per_country/1"

      assert_response :success
      result = @controller.view_assigns["result"]
      assert_equal 1, result.blocked_by_country
      assert_equal 2, result.blocked_by_author
      note = css_select("[data-testid=canon-short-list-note]").first.text
      assert_match(/per country/, note)
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

    test "an excluded genre removes its books from the canon" do
      poetry = ::Books::Category.create!(name: "Poetry", slug: "poetry", category_type: :genre)
      excluded_book = ::Books::Book.where(title: "Canon Book 1").first
      ::CategoryItem.create!(category: poetry, item: excluded_book)

      get "/global-canon/total_books/50/nonfiction/0/max_per_country/10/excluding/poetry"

      assert_response :success
      ids = @controller.view_assigns["result"].ranked_items.map(&:item_id)
      refute_includes ids, excluded_book.id
      assert_equal 2, ids.size
    end

    test "an excluded genre path is noindex" do
      Books::PublicIndexing.stubs(:enabled?).returns(true)
      ::Books::Category.create!(name: "Poetry", slug: "poetry", category_type: :genre)

      get "/global-canon/total_books/150/nonfiction/20/max_per_country/3/excluding/poetry"

      assert_select "meta[name=robots][content=?]", "noindex, follow"
    end

    test "an unsorted exclusion list 301s to the sorted one" do
      ::Books::Category.create!(name: "Poetry", slug: "poetry", category_type: :genre)
      ::Books::Category.create!(name: "Fantasy", slug: "fantasy", category_type: :genre)

      get "/global-canon/total_books/150/nonfiction/20/max_per_country/3/excluding/poetry,fantasy"

      assert_redirected_to "/global-canon/total_books/150/nonfiction/20/max_per_country/3/excluding/fantasy,poetry"
      assert_equal 301, response.status
    end

    test "the settings form carries exclusions into the canonical path" do
      ::Books::Category.create!(name: "Poetry", slug: "poetry", category_type: :genre)

      get "/global-canon/settings", params: {
        total_books: "150", nonfiction_percentage: "20",
        max_books_per_country: "3", excluded_genres: ["poetry"]
      }

      assert_redirected_to "/global-canon/total_books/150/nonfiction/20/max_per_country/3/excluding/poetry"
    end

    test "an unknown genre slug 404s" do
      # The route regex admits any lowercase slug, so this reaches the app and
      # GlobalCanonParams is what rejects it. That is the whole reason the
      # validator duplicates the constraint.
      get "/global-canon/total_books/150/nonfiction/20/max_per_country/3/excluding/not-a-genre"

      assert_response :not_found
    end

    test "more than six exclusions never reaches the app" do
      slugs = (1..7).map { |i| ::Books::Category.create!(name: "Genre #{i}", slug: "genre-#{i}", category_type: :genre).slug }

      get "/global-canon/total_books/150/nonfiction/20/max_per_country/3/excluding/#{slugs.join(",")}"

      assert_response :not_found
    end

    test "the genres endpoint returns matching genres as slug and name" do
      ::Books::Category.create!(name: "Poetry", slug: "poetry", category_type: :genre)

      get "/global-canon/genres", params: {q: "poet"}, as: :json

      assert_response :success
      assert_equal [{"value" => "poetry", "text" => "Poetry"}], response.parsed_body
    end

    test "the genres endpoint excludes subjects and settings" do
      subject = categories(:books_politics_subject)
      location = categories(:books_france_location)

      get "/global-canon/genres", params: {q: subject.name}, as: :json

      assert_response :success
      refute_includes response.parsed_body.map { |row| row["value"] }, subject.slug

      # A location (setting) slug must be excluded too: GlobalCanonParams 404s
      # a location slug, so if this endpoint ever offered one, the picker
      # could hand the visitor a choice that breaks the page.
      get "/global-canon/genres", params: {q: location.name}, as: :json

      assert_response :success
      refute_includes response.parsed_body.map { |row| row["value"] }, location.slug
    end

    test "the genres endpoint is never cached" do
      get "/global-canon/genres", params: {q: "poet"}, as: :json

      assert_match "no-store", response.headers["Cache-Control"]
    end

    test "the genres endpoint never looks up a ranking configuration" do
      # find_ranking_configuration is scoped to :show only -- #genres is the
      # exclusion picker's search-as-you-type source and fires on every
      # keystroke, so an uncached default_primary lookup there would be a
      # wasted query per keystroke (and a nil RC would 404 the JSON endpoint
      # for an unrelated reason).
      Books::RankingConfiguration.expects(:default_primary).never

      get "/global-canon/genres", params: {q: "poet"}, as: :json

      assert_response :success
    end

    test "the genre picker renders MAX_EXCLUDED_GENRES as its cap for the JS controller to read" do
      # Books::GlobalCanonParams 404s past MAX_EXCLUDED_GENRES, but the picker
      # JS (saved_search_picker_controller.js) has no way to know that number
      # except by reading it off the DOM -- this pins that the view actually
      # renders it, rather than hardcoding 6 in the template.
      get "/global-canon"

      assert_response :success
      assert_select "[data-testid=canon-genre-picker][data-saved-search-picker-max-value=?]",
        Books::GlobalCanonParams::MAX_EXCLUDED_GENRES.to_s
    end

    test "an off-menu non-fiction percentage is preselected, not silently defaulted to 0%" do
      # options_for_select emits no `selected` attribute for a value absent
      # from the option list, so the browser falls back to displaying the
      # FIRST option (0%) -- even though the page body correctly says 37%.
      get "/global-canon/total_books/250/nonfiction/37/max_per_country/2"

      assert_response :success
      assert_select "select#nonfiction_percentage option[selected][value=?]", "37"
    end

    test "cards are numbered by canon position, not the book's own global rank" do
      # Excluding "Canon Book 1" (global rank 1) via genre makes the first
      # DELIVERED book "Canon Book 2" (global rank 2) -- so canon position 1
      # and global rank 1 point at different books, and only the position
      # numbering (index + 1) can be correct for both.
      poetry = ::Books::Category.create!(name: "Poetry", slug: "poetry", category_type: :genre)
      rank_one_book = ::Books::Book.where(title: "Canon Book 1").first
      ::CategoryItem.create!(category: poetry, item: rank_one_book)

      get "/global-canon/total_books/50/nonfiction/0/max_per_country/10/excluding/poetry"

      assert_response :success
      ranked_items = @controller.view_assigns["result"].ranked_items
      # Sanity check on the scenario itself: the first delivered book's own
      # rank is 2, not 1 -- proving this test can actually distinguish
      # canon position from global rank.
      assert_equal 2, ranked_items.first.rank

      first_card_badge = css_select(".card").first.css(".badge-primary").first.text.squish
      assert_equal "Rank #1", first_card_badge
    end

    test "the aggregated-lists count scopes to Books::List, not the shared List model" do
      # List (root namespace) spans all four sites this app serves. Creating
      # an extra ACTIVE Books::List and asserting the page renders exactly
      # Books::List.active.count -- not the (necessarily larger) List.active.count
      # -- is what a `Books::List.active` -> `List.active` substitution breaks.
      ::Books::List.create!(name: "Extra Active Books List", status: :active)

      expected = ::Books::List.active.count
      assert_operator expected, :<, ::List.active.count

      get "/global-canon"

      assert_response :success
      assert_select "p", /built from #{expected} aggregated lists/
    end

    test "an excluded genre is echoed back as a chip and named in the exclusion sentence" do
      poetry = ::Books::Category.create!(name: "Poetry", slug: "poetry", category_type: :genre)

      get "/global-canon/total_books/150/nonfiction/20/max_per_country/3/excluding/poetry"

      assert_response :success
      assert_select "[data-chip=?]", poetry.slug
      assert_select "p", /Excluding Poetry\./
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

    def rank_fiction_book(country: nil, author: nil)
      @next_rank += 1
      book = ::Books::Book.create!(title: "Canon Book #{@next_rank}")
      ::Books::BookCountry.create!(book: book, country: country) if country
      ::Books::BookAuthor.create!(
        book: book, author: author || ::Books::Author.create!(name: "Author #{@next_rank}"),
        position: 1, role: :author
      )
      ::CategoryItem.create!(category: @fiction, item: book)
      ::RankedItem.create!(item: book, ranking_configuration: @rc, rank: @next_rank, score: 10_000 - @next_rank)
      book
    end
  end
end
