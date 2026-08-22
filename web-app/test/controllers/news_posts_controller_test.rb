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
end
