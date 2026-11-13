require "test_helper"

class SitemapsControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! Rails.application.config.domains[:music].split(",").first
  end

  test "index lists one child per source page with absolute urls" do
    get "/sitemap.xml"
    assert_response :success
    assert_equal "application/xml", response.media_type
    locs = Nokogiri::XML(response.body).remove_namespaces!.xpath("//sitemap/loc").map(&:text)
    assert_includes locs, "#{Api::Host.base_url(:music)}/sitemaps/pages-1.xml"
  end

  test "index splits a source across files at page_size" do
    Sitemaps::Registry.stubs(:page_size).returns(2)
    get "/sitemap.xml"
    assert_includes response.body, "/sitemaps/pages-4.xml"
    assert_not_includes response.body, "/sitemaps/pages-5.xml"
  end

  test "child file lists urls" do
    get "/sitemaps/pages-1.xml"
    locs = Nokogiri::XML(response.body).remove_namespaces!.xpath("//url/loc").map(&:text)
    assert_includes locs, "#{Api::Host.base_url(:music)}/albums"
  end

  test "child file emits lastmod only for entries that have one" do
    host! Rails.application.config.domains[:books].split(",").first
    ::Books::PublicIndexing.stubs(:enabled?).returns(true)
    get "/sitemaps/news-1.xml"
    doc = Nokogiri::XML(response.body).remove_namespaces!
    assert_equal 2, doc.xpath("//url").size
    assert_equal [news_posts(:books_december_update).updated_at.iso8601], doc.xpath("//url/lastmod").map(&:text)
    get "/sitemaps/pages-1.xml"
    assert_empty Nokogiri::XML(response.body).remove_namespaces!.xpath("//url/lastmod")
  end

  test "unknown key, page 0 and page past the end 404" do
    get "/sitemaps/nope-1.xml"
    assert_response :not_found
    get "/sitemaps/pages-0.xml"
    assert_response :not_found
    get "/sitemaps/pages-2.xml"
    assert_response :not_found
  end

  test "index lists no news child when the site has no published posts" do
    NewsPost.where(domain: :music).update_all(published_at: 1.day.from_now)
    get "/sitemap.xml"
    assert_response :success
    assert_not_includes response.body, "/sitemaps/news-"
    get "/sitemaps/news-1.xml"
    assert_response :not_found
  end

  test "another site's source key 404s" do
    host! Rails.application.config.domains[:games].split(",").first
    get "/sitemaps/songs-1.xml"
    assert_response :not_found
  end

  test "a books child file 404s while gated" do
    host! Rails.application.config.domains[:books].split(",").first
    ::Books::PublicIndexing.stubs(:enabled?).returns(false)
    get "/sitemaps/pages-1.xml"
    assert_response :not_found
  end

  test "a zero-padded page number does not route" do
    get "/sitemaps/pages-01.xml"
    assert_response :not_found
  end

  test "books 404s while gated and serves once enabled" do
    host! Rails.application.config.domains[:books].split(",").first
    ::Books::PublicIndexing.stubs(:enabled?).returns(false)
    get "/sitemap.xml"
    assert_response :not_found
    ::Books::PublicIndexing.stubs(:enabled?).returns(true)
    get "/sitemap.xml"
    assert_response :success
  end

  test "a source key containing an underscore routes with the page split at the hyphen" do
    Sitemaps::Registry.expects(:find).with(:music, "album_lists")
      .returns(Sitemaps::StaticPages.new(paths: %w[/a /b /c]))
    Sitemaps::Registry.stubs(:page_size).returns(2)
    get "/sitemaps/album_lists-2.xml"
    assert_response :success
    assert_equal ["#{Api::Host.base_url(:music)}/c"],
      Nokogiri::XML(response.body).remove_namespaces!.xpath("//url/loc").map(&:text)
  end

  test "movies host does not route" do
    host! Rails.application.config.domains[:movies].split(",").first
    get "/sitemap.xml"
    assert_response :not_found
  end

  test "responses are publicly cacheable without a session cookie" do
    get "/sitemap.xml"
    assert_includes response.headers["Cache-Control"], "public"
    assert_includes response.headers["Cache-Control"], "max-age=86400"
    assert_nil response.headers["Set-Cookie"]
  end
end
