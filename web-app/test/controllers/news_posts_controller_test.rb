require "test_helper"

class NewsPostsControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! "dev-new.thegreatestbooks.org"
  end

  test "index lists only this domain's published posts" do
    get news_path

    assert_response :success
    assert_equal [news_posts(:books_december_update).id],
      @controller.view_assigns["news_posts"].map(&:id)
  end

  test "index excludes drafts" do
    get news_path

    ids = @controller.view_assigns["news_posts"].map(&:id)
    assert_includes ids, news_posts(:books_december_update).id # positive control
    assert_not_includes ids, news_posts(:books_draft).id
  end

  test "index excludes future-dated posts" do
    get news_path

    ids = @controller.view_assigns["news_posts"].map(&:id)
    assert_includes ids, news_posts(:books_december_update).id # positive control
    assert_not_includes ids, news_posts(:books_scheduled).id
  end

  test "index excludes another domain's posts" do
    get news_path

    ids = @controller.view_assigns["news_posts"].map(&:id)
    assert_includes ids, news_posts(:books_december_update).id # positive control
    assert_not_includes ids, news_posts(:music_launch).id
  end

  test "index orders newest first" do
    # newest is the fixture (lower id, published_at closer to now); oldest is
    # created at runtime (higher id, published_at far in the past) -- id order
    # and publish order disagree, so this cannot pass by coinciding with
    # `order(id: :desc)` alone.
    newest = news_posts(:books_december_update)
    oldest = NewsPost.create!(domain: :books, title: "Older", body: "hi",
      user: users(:admin_user), published_at: 30.days.ago)

    get news_path

    assert_equal [newest.id, oldest.id], @controller.view_assigns["news_posts"].map(&:id)
  end

  test "index renders the post title and summary" do
    get news_path

    assert_select "h2", text: /December Update/
    assert_includes response.body, "The December update."
  end

  test "index is edge cacheable" do
    get news_path

    assert_match(/max-age=21600/, response.headers["Cache-Control"])
    assert_match(/public/, response.headers["Cache-Control"])
  end

  test "index serves the books layout on the books host" do
    get news_path

    assert_select "html[data-theme=books]"
  end

  test "index pagination links are path based" do
    12.times do |i|
      NewsPost.create!(domain: :books, title: "Filler #{i}", body: "x",
        user: users(:admin_user), published_at: (i + 2).hours.ago)
    end

    get news_path

    assert_select "nav.pagy a[href='/news/page/2']"
    assert_equal "/news/page/2", @controller.view_assigns["pagy"].page_url(2)
  end

  test "a page past the last one 404s rather than serving an empty cacheable page" do
    get news_page_path(page: 99)

    assert_response :not_found
    assert_match(/no-store/, response.headers["Cache-Control"])
  end

  # Fix 1(b): /news/page/0 and /news/page/01 must not be a second, distinct
  # 200 for the same content as /news -- {page: /[1-9]\d*/} rejects the
  # non-canonical numeral before the controller (and Cacheable) ever see it.
  test "news/page/0 404s rather than serving duplicate content" do
    get "/news/page/0"

    assert_response :not_found
  end

  test "news/page/01 404s rather than serving duplicate content" do
    get "/news/page/01"

    assert_response :not_found
  end

  # Fix 1(a): #index sets no canonical today, so five distinct URLs
  # (/news, /news?utm_source=x, /news.html, /news/page/0, /news/page/01) all
  # served byte-identical 200s with no <link rel="canonical">. This pins the
  # bare-path case; the tracking-parameter and later-page cases follow below.
  test "index sets a canonical url" do
    get news_path

    assert_select "link[rel=canonical][href=?]", "http://dev-new.thegreatestbooks.org/news"
  end

  test "index sets a canonical url on a later page" do
    12.times do |i|
      NewsPost.create!(domain: :books, title: "Filler #{i}", body: "x",
        user: users(:admin_user), published_at: (i + 2).hours.ago)
    end

    get news_page_path(page: 2)

    assert_select "link[rel=canonical][href=?]",
      "http://dev-new.thegreatestbooks.org/news/page/2"
  end

  test "a topic page sets a canonical url" do
    get news_topic_path(topic_slug: "rankings")

    assert_select "link[rel=canonical][href=?]",
      "http://dev-new.thegreatestbooks.org/news/topic/rankings"
  end

  # A URL carrying a tracking parameter is a distinct share object from the
  # bare canonical URL and must not advertise itself as one -- the same
  # invariant #show already holds (D4). request.original_url would echo the
  # query string; the canonical/og:url pair must not.
  test "index's og:url matches the canonical url even with tracking parameters" do
    get news_path(utm_source: "twitter")

    assert_select "meta[property='og:url'][content=?]",
      "http://dev-new.thegreatestbooks.org/news"
  end

  test "index on the music host lists music posts" do
    host! "dev.thegreatestmusic.org"

    get news_path

    assert_equal [news_posts(:music_launch).id],
      @controller.view_assigns["news_posts"].map(&:id)
  end

  test "a topic page lists only that topic's posts" do
    get news_topic_path(topic_slug: "rankings")

    assert_response :success
    assert_equal [news_posts(:books_december_update).id],
      @controller.view_assigns["news_posts"].map(&:id)
  end

  test "another domain's topic 404s" do
    get news_topic_path(topic_slug: "site-news")

    assert_response :not_found
  end

  test "index is indexable" do
    Books::PublicIndexing.stubs(:enabled?).returns(true)

    get news_path

    assert_select "meta[name=robots][content=?]", "index, follow"
  end

  test "an index with no posts is not indexable" do
    # destroy_all, not delete_all: books_december_update has a news_post_topics
    # join row (december_update_rankings), and delete_all bypasses the
    # dependent: :destroy callback that cleans it up, raising a foreign key
    # violation instead of emptying the domain.
    Books::PublicIndexing.stubs(:enabled?).returns(true)
    NewsPost.where(domain: :books).destroy_all

    get news_path

    assert_select "meta[name=robots][content=?]", "noindex, follow"
  end

  test "an empty index on the games host is not indexable" do
    # books/default_helper.rb defaults to noindex whenever @indexable is
    # false, nil, OR never assigned -- so a books-only empty-index assertion
    # is satisfied by the pre-existing (unassigned) state and cannot tell
    # `@indexable = @news_posts.any?` apart from no assignment at all.
    # games/default_helper.rb inverts that default (index unless
    # @indexable == false), so only the games host actually discriminates.
    # Games holds no posts in fixtures, so no cleanup is needed.
    host! "dev.thegreatest.games"

    get news_path

    assert_select "meta[name=robots][content=?]", "noindex, follow"
  end

  # Fix 5: /news is a global route, live on thegreatestmusic.org the moment
  # this merges, and music/application.html.erb rendered no robots meta at
  # all before this. music_robots_content mirrors games' opt-out semantics
  # (see the games test above for why only an opt-out helper discriminates
  # `@indexable = @news_posts.any?` from an unassigned default).
  test "an empty index on the music host emits a noindex robots tag" do
    # destroy_all, not delete_all: matches the books empty-index test's
    # reasoning above, and is safe here even though music_launch has no
    # news_post_topics join row today.
    NewsPost.where(domain: :music).destroy_all
    host! "dev.thegreatestmusic.org"

    get news_path

    assert_response :success
    assert_select "meta[name=robots][content=?]", "noindex, follow"
  end

  test "page 1 canonicalises to the bare path" do
    get "/news/page/1"

    assert_redirected_to "/news"
    assert_response :moved_permanently
  end

  test "a signed-in visitor sees the same posts as an anonymous one, and never a draft" do
    sign_in_as(users(:admin_user), stub_auth: true)

    get news_path

    assert_response :success
    ids = @controller.view_assigns["news_posts"].map(&:id)
    assert_equal [news_posts(:books_december_update).id], ids
    assert_not_includes response.body, "Something Unfinished"
    assert_match(/max-age=21600/, response.headers["Cache-Control"])
    assert_match(/public/, response.headers["Cache-Control"])
  end

  test "show renders a published post" do
    get news_post_path(slug: "december-update")

    assert_response :success
    assert_select "h1", text: /December Update/
  end

  test "show renders the body as HTML from Markdown" do
    get news_post_path(slug: "december-update")

    assert_includes response.body, "<strong>Rankings</strong>"
  end

  # D1: rescue_from ActiveRecord::RecordNotFound (application_controller.rb:9)
  # means the exception never escapes the controller -- assert_response
  # :not_found, not assert_raises.
  test "show 404s for a draft" do
    get news_post_path(slug: "something-unfinished")

    assert_response :not_found
    # render_not_found also calls prevent_caching, so a draft's 404 must
    # never be edge-cached alongside the published show action's 24h header.
    assert_match(/no-store/, response.headers["Cache-Control"])
  end

  test "show 404s for a future-dated post" do
    get news_post_path(slug: "next-week")

    assert_response :not_found
  end

  test "show 404s for another domain's post" do
    get news_post_path(slug: "the-greatest-music-is-live")

    assert_response :not_found
  end

  test "show is edge cacheable for 24 hours" do
    get news_post_path(slug: "december-update")

    assert_match(/max-age=86400/, response.headers["Cache-Control"])
    assert_match(/public/, response.headers["Cache-Control"])
  end

  test "show sets a canonical url" do
    get news_post_path(slug: "december-update")

    assert_select "link[rel=canonical][href=?]",
      "http://dev-new.thegreatestbooks.org/news/december-update"
  end

  test "show emits Open Graph tags" do
    get news_post_path(slug: "december-update")

    assert_select "meta[property='og:title'][content=?]", "December Update"
    assert_select "meta[property='og:type'][content=?]", "article"
    assert_select "meta[property='og:description'][content=?]", "The December update."
  end

  # D4: og:url must follow the canonical URL, not request.original_url, or a
  # shared link with tracking params (?utm_source=twitter) would advertise
  # itself as a distinct share target from the bare canonical URL. This
  # request carries a query string specifically so a naive
  # request.original_url implementation would fail it.
  test "show's og:url matches the canonical url even with tracking parameters" do
    get news_post_path(slug: "december-update", utm_source: "twitter")

    assert_select "meta[property='og:url'][content=?]",
      "http://dev-new.thegreatestbooks.org/news/december-update"
  end

  # D2: @indexable defaults to nil, so without an explicit assignment a post
  # page would ship noindex -- on exactly the URLs ~156k legacy links 301 into.
  test "show is indexable" do
    Books::PublicIndexing.stubs(:enabled?).returns(true)

    get news_post_path(slug: "december-update")

    assert_select "meta[name=robots][content=?]", "index, follow"
  end

  # D3: og:image must be an absolute URL (scrapers ignore relative ones) and
  # must go through the images CDN, not the Rails origin.
  test "show emits an absolute og:image when a share image is attached" do
    post = news_posts(:books_december_update)
    post.share_image.attach(io: File.open(file_fixture("test_image.png")),
      filename: "card.png", content_type: "image/png")

    get news_post_path(slug: "december-update")

    tag = css_select("meta[property='og:image']").first
    refute_nil tag, "expected an og:image meta tag, found none"
    content = tag["content"]
    assert content.start_with?("https://"),
      "og:image must be absolute for share-card scrapers, got #{content.inspect}"
    assert_not_includes content, "/rails/active_storage/",
      "og:image must go through the images CDN, not the Rails origin, got #{content.inspect}"
    assert_select "meta[name='twitter:card'][content=?]", "summary_large_image"
  end

  test "show falls back to a summary card when no share image is attached" do
    get news_post_path(slug: "december-update")

    assert_select "meta[property='og:image']", false
    assert_select "meta[name='twitter:card'][content=?]", "summary"
  end

  # Named for what it checks, not the route: news_path is only the vehicle
  # because #index never sets og_type, exercising the layout's own fallback.
  test "a page that sets no og:type falls back to the website default" do
    get news_path

    assert_select "meta[property='og:type'][content=?]", "website"
  end

  # D5: presence alone ("meta[property='og:title']") passes whether or not the
  # page is unaffected -- it is satisfied by a layout that emits an empty
  # content for every page in the app. Assert the page's own concrete values
  # instead, per app/views/books/lists/index.html.erb:2-3.
  test "an existing books page renders and its Open Graph tags follow its own title" do
    get "/lists"

    assert_response :success
    assert_select "meta[property='og:title'][content=?]",
      "The Greatest Books Lists | The Greatest Books"
    assert_select "meta[property='og:description'][content=?]",
      "Every published best-books list we aggregate to build the rankings, weighted by quality, credibility and scope."
  end

  # Review finding: strip_tags decodes an already-escaped content_for buffer
  # and returns it html_safe, so ERB does not re-escape it and a literal
  # double quote in the fallback breaks out of the content="" attribute. The
  # /lists test above can't catch this -- its title is a hardcoded,
  # quote-free constant. A news topic page never sets og_title, so it drives
  # the layout's fallback branch with a hostile value.
  test "the og:title fallback survives a title containing a double quote" do
    topic = NewsTopic.create!(domain: :books, name: 'The "Best" Rankings')
    domain_name = Rails.application.config.domain_settings[:books][:name]

    get news_topic_path(topic_slug: topic.slug)

    assert_response :success
    assert_select "meta[property='og:title'][content=?]",
      "The \"Best\" Rankings | News | #{domain_name}"
  end

  # "a topic page lists only that topic's posts" and "another domain's topic
  # 404s" were pulled forward into Task 14 (see test above) -- not duplicated
  # here.

  # E2: the fixtures hold exactly one published books post, so the test above
  # cannot tell the joins(...) clause in #index apart from the plain domain
  # scope -- deleting the topic filter still returns [books_december_update]
  # unchanged. This test creates a SECOND, untagged books post, which is the
  # one fixture condition that discriminates the clause. It is the only test
  # in the suite that can catch that join disappearing.
  test "a topic page excludes posts without that topic" do
    other = NewsPost.create!(domain: :books, title: "Untagged", body: "x",
      user: users(:admin_user), published_at: 1.hour.ago)

    get news_topic_path(topic_slug: "rankings")

    ids = @controller.view_assigns["news_posts"].map(&:id)
    assert_includes ids, news_posts(:books_december_update).id # positive control
    assert_not_includes ids, other.id
  end

  test "a topic page still excludes drafts" do
    news_posts(:books_draft).news_topics << news_topics(:books_rankings)

    get news_topic_path(topic_slug: "rankings")

    ids = @controller.view_assigns["news_posts"].map(&:id)
    assert_includes ids, news_posts(:books_december_update).id # positive control
    assert_not_includes ids, news_posts(:books_draft).id
  end

  # E3: rescue_from ActiveRecord::RecordNotFound (application_controller.rb:9)
  # means the exception never escapes the controller -- assert_response
  # :not_found, not assert_raises.
  test "an unknown topic 404s" do
    get news_topic_path(topic_slug: "no-such-topic")

    assert_response :not_found
  end

  test "a topic page names the topic in its heading" do
    get news_topic_path(topic_slug: "rankings")

    assert_select "h1", text: "Rankings"
  end

  # Fix 2: news_topic_page and its /page/1 301 appeared in no controller test
  # and no E2E spec -- a test gap on public, path-based paging, a standing
  # landmine in this codebase. The fixture topic already carries one tagged
  # post (december_update_rankings), so 12 new tagged posts make 13 total: 10
  # on page 1, 3 on page 2.
  test "a topic's pagination links are path based" do
    12.times do |i|
      post = NewsPost.create!(domain: :books, title: "Topic Filler #{i}", body: "x",
        user: users(:admin_user), published_at: (i + 1).hours.ago)
      post.news_topics << news_topics(:books_rankings)
    end

    get news_topic_path(topic_slug: "rankings")

    assert_select "nav.pagy a[href='/news/topic/rankings/page/2']"
    assert_equal "/news/topic/rankings/page/2", @controller.view_assigns["pagy"].page_url(2)
  end

  test "a topic's second page lists the remaining posts" do
    posts = 12.times.map do |i|
      post = NewsPost.create!(domain: :books, title: "Topic Filler #{i}", body: "x",
        user: users(:admin_user), published_at: (i + 1).hours.ago)
      post.news_topics << news_topics(:books_rankings)
      post
    end

    get news_topic_page_path(topic_slug: "rankings", page: 2)

    assert_response :success
    # The 10 most recent (i = 0..9, 1h-10h ago) land on page 1; the 2 oldest
    # new posts (i = 10, 11) plus the 3-day-old fixture land on page 2, newest
    # first.
    expected_ids = [posts[10].id, posts[11].id, news_posts(:books_december_update).id]
    assert_equal expected_ids, @controller.view_assigns["news_posts"].map(&:id)
  end

  test "a topic's page 1 canonicalises to the bare topic path" do
    get "/news/topic/rankings/page/1"

    assert_redirected_to "/news/topic/rankings"
    assert_response :moved_permanently
  end

  test "the legacy blog index 301s to news" do
    get "/blog_posts"

    assert_redirected_to "/news"
    assert_response :moved_permanently
  end

  test "a legacy blog post url 301s to its news url" do
    get "/blog_posts/december-update"

    assert_redirected_to "/news/december-update"
    assert_response :moved_permanently
  end

  # E5: the legacy redirects belong inside the books domain constraint --
  # music and games never had a /blog_posts URL space, so they must not gain
  # a 301 for it now.
  test "the legacy blog urls are books-only" do
    host! "dev.thegreatestmusic.org"

    get "/blog_posts"

    assert_response :not_found
  end

  # E7: /news returning :success was already true before this task -- what
  # this actually guards is that adding the /blog_posts redirects doesn't
  # also add a mistaken get "news", to: redirect(...) alongside them, since
  # /news is the legacy blog's index path too and must NOT redirect.
  test "the legacy news index path still resolves" do
    get "/news"

    assert_response :success
  end
end
