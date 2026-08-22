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
    older = news_posts(:books_december_update)
    newer = NewsPost.create!(domain: :books, title: "Newer", body: "hi",
      user: users(:admin_user), published_at: 1.hour.ago)

    get news_path

    assert_equal [newer.id, older.id], @controller.view_assigns["news_posts"].map(&:id)
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
  end

  test "index on the music host lists music posts" do
    host! "dev.thegreatestmusic.org"

    get news_path

    assert_equal [news_posts(:music_launch).id],
      @controller.view_assigns["news_posts"].map(&:id)
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
  end
end
