require "test_helper"

class PagesControllerTest < ActionDispatch::IntegrationTest
  # Each site's layout, keyed by the theme it stamps on <html> -- the same
  # signal news_posts_controller_test uses to prove DomainLayout resolved.
  SITES = {
    books: "books",
    music: "light",
    games: "abyss"
  }.freeze

  def host_for(domain)
    Rails.application.config.domains[domain].to_s.split(",").first
  end

  SITES.each do |domain, theme|
    test "privacy policy renders in the #{domain} layout on the #{domain} host" do
      host! host_for(domain)

      get "/privacy_policy"

      assert_response :success
      assert_select "html[data-theme=#{theme}]"
    end

    test "deletion policy renders in the #{domain} layout on the #{domain} host" do
      host! host_for(domain)

      get "/deletion_policy"

      assert_response :success
      assert_select "html[data-theme=#{theme}]"
    end
  end

  # The footer lives in each site's layout, so proving it renders on one page of
  # a site proves it renders on every page of that site. Scoped to <footer>
  # deliberately: the policy pages link to each other in their body text, so an
  # unscoped selector would pass with no footer at all.
  SITES.each_key do |domain|
    test "the #{domain} layout renders the shared footer" do
      host! host_for(domain)

      get "/privacy_policy"

      assert_select "footer a[href=?]", "/privacy_policy"
      assert_select "footer a[href=?]", "/deletion_policy"
      assert_select "footer a[href=?]", "/news"
      assert_select "footer a[href=?]", "mailto:#{SiteContact::ADDRESS}"
    end
  end

  # The legacy site has served these two paths for years and the footer links
  # point at them; a rename would break every inbound link at once.
  test "keeps the legacy paths" do
    assert_equal "/privacy_policy", privacy_policy_path
    assert_equal "/deletion_policy", deletion_policy_path
  end

  # Constrained to the three built sites, exactly like the /news routes. Without
  # a constraint these also answer on the fourth host, which is a placeholder.
  test "the policy routes serve only the three implemented sites" do
    host! host_for(:movies)

    get "/privacy_policy"
    assert_response :not_found

    get "/deletion_policy"
    assert_response :not_found
  end

  test "privacy policy is edge cacheable" do
    host! host_for(:books)

    get "/privacy_policy"

    assert_match(/max-age=86400/, response.headers["Cache-Control"])
    assert_match(/public/, response.headers["Cache-Control"])
  end

  test "deletion policy is edge cacheable" do
    host! host_for(:books)

    get "/deletion_policy"

    assert_match(/max-age=86400/, response.headers["Cache-Control"])
    assert_match(/public/, response.headers["Cache-Control"])
  end

  # Cloudflare bypasses the cache entirely when Set-Cookie is present, so a
  # session cookie here would quietly undo the max-age above.
  test "policy pages set no cookie so the edge will actually cache them" do
    host! host_for(:books)

    get "/privacy_policy"

    assert_nil response.headers["Set-Cookie"]
  end

  # The three sites' robots helpers have OPPOSITE defaults: music and games are
  # opt-out (`@indexable == false ? noindex : index`) while books is opt-in
  # (`@indexable ? index : noindex`). So a controller that sets nothing gets the
  # same page indexed on two sites and hidden on the third by accident. Books is
  # gated behind BOOKS_PUBLIC_INDEXING as well, which is off pre-cutover, so this
  # only surfaces at cutover -- when nobody will be looking at the policy pages.
  #
  # Stubbed rather than driven by ENV: .env loads in the test group, so an
  # env-dependent assertion here would pass locally and prove nothing about CI.
  SITES.each_key do |domain|
    test "the #{domain} policy pages are indexable" do
      Books::PublicIndexing.stubs(:enabled?).returns(true)
      host! host_for(domain)

      get "/privacy_policy"
      assert_select "meta[name=robots][content=?]", "index, follow"

      get "/deletion_policy"
      assert_select "meta[name=robots][content=?]", "index, follow"
    end
  end

  # A deletion policy that does not tell you how to request deletion is not a
  # deletion policy. Asserts the mechanism is wired, not the wording.
  test "deletion policy offers a way to make the request" do
    host! host_for(:books)

    get "/deletion_policy"

    assert_select "a[href=?]", "mailto:#{SiteContact::ADDRESS}", minimum: 1
  end
end
