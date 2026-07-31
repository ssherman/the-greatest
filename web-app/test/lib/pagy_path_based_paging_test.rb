require "test_helper"
require "pagy/classes/request"

class PagyPathBasedPagingTest < ActiveSupport::TestCase
  PATH_BUILDER = ->(n) { (n.to_i <= 1) ? "/" : "/page/#{n.to_i}" }

  def build_pagy(params:, path: "/", **extra)
    options = {count: 24_242, limit: 100, page_key: "page",
               request: {base_url: "https://books.test", path: path, params: params}}.merge(extra)
    options[:request] = Pagy::Request.new(options)
    options[:page] = options[:request].resolve_page
    Pagy::Offset.new(**options)
  end

  test "generates path-based urls when page_path is supplied" do
    pagy = build_pagy(params: {"page" => "12"}, path: "/page/12", page_path: PATH_BUILDER)

    assert_equal "/", pagy.page_url(1)
    assert_equal "/page/2", pagy.page_url(2)
    assert_equal "/page/243", pagy.page_url(243)
  end

  test "leaves query-string pagination untouched when page_path is absent" do
    pagy = build_pagy(params: {"page" => "3"}, path: "/video-games")

    assert_equal "/video-games?page=4", pagy.page_url(4)
  end

  test "series_nav links page one at the root path, never /page/1" do
    nav = build_pagy(params: {"page" => "2"}, path: "/page/2", page_path: PATH_BUILDER).series_nav(slots: 5)

    assert_includes nav, %(href="/" rel="prev")
    refute_includes nav, "/page/1"
  end

  test "series_nav emits well-formed anchors" do
    nav = build_pagy(params: {"page" => "12"}, path: "/page/12", page_path: PATH_BUILDER).series_nav(slots: 5)

    assert_includes nav, %(<a href="/page/13" rel="next">13</a>)
    refute_includes nav, %(href="/"1)
  end

  test "preserves unrelated query parameters" do
    pagy = build_pagy(params: {"page" => "12", "sort" => "title"}, path: "/page/12", page_path: PATH_BUILDER)

    assert_equal "/page/3?sort=title", pagy.page_url(3)
  end

  test "resolves the page from a route parameter" do
    assert_equal 12, build_pagy(params: {"page" => "12"}, path: "/page/12", page_path: PATH_BUILDER).page
  end

  test "still resolves the page from a query parameter" do
    assert_equal 7, build_pagy(params: {"page" => "7"}, path: "/", page_path: PATH_BUILDER).page
  end

  test "raises instead of silently corrupting a token-based helper when page_path is set" do
    pagy = build_pagy(params: {"page" => "2"}, path: "/page/2", page_path: PATH_BUILDER)

    error = assert_raises(Pagy::InternalError) { pagy.urls_hash }
    assert_match(/page_path/, error.message)
  end

  test "page_url still works normally alongside the token-based guard" do
    pagy = build_pagy(params: {"page" => "2"}, path: "/page/2", page_path: PATH_BUILDER)

    assert_equal "/page/3", pagy.page_url(3)
  end
end
