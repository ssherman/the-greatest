require "test_helper"

class RobotsControllerTest < ActionDispatch::IntegrationTest
  RULES = File.read(Rails.root.join("test/fixtures/files/robots_rules.txt"))

  def host_for(domain)
    host! Rails.application.config.domains[domain].split(",").first
  end

  test "music: rules unchanged plus sitemap line" do
    host_for(:music)
    get "/robots.txt"
    assert_response :success
    assert_equal "text/plain", response.media_type
    assert_equal RULES + "\nSitemap: #{Api::Host.base_url(:music)}/sitemap.xml\n", response.body
  end

  test "games: rules unchanged plus sitemap line" do
    host_for(:games)
    get "/robots.txt"
    assert_equal RULES + "\nSitemap: #{Api::Host.base_url(:games)}/sitemap.xml\n", response.body
  end

  test "books gated: rules only" do
    host_for(:books)
    ::Books::PublicIndexing.stubs(:enabled?).returns(false)
    get "/robots.txt"
    assert_response :success
    assert_equal "text/plain", response.media_type
    assert_equal RULES, response.body
  end

  test "books enabled: sitemap line" do
    host_for(:books)
    ::Books::PublicIndexing.stubs(:enabled?).returns(true)
    get "/robots.txt"
    assert_equal RULES + "\nSitemap: #{Api::Host.base_url(:books)}/sitemap.xml\n", response.body
  end

  test "movies: rules only" do
    host_for(:movies)
    get "/robots.txt"
    assert_response :success
    assert_equal "text/plain", response.media_type
    assert_equal RULES, response.body
  end

  test "cacheable without a session cookie" do
    host_for(:music)
    get "/robots.txt"
    assert_nil response.headers["Set-Cookie"]
    assert_includes response.headers["Cache-Control"], "public"
    assert_includes response.headers["Cache-Control"], "max-age=86400"
  end
end
