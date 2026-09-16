require "test_helper"

class DevelopersControllerTest < ActionDispatch::IntegrationTest
  # Each site's layout, keyed by the theme it stamps on <html> -- the same
  # signal pages_controller_test uses to prove DomainLayout resolved.
  SITES = {
    books: "books",
    music: "light",
    games: "abyss"
  }.freeze

  def host_for(domain)
    Rails.application.config.domains[domain].to_s.split(",").first
  end

  SITES.each do |domain, theme|
    test "renders in the #{domain} layout on the #{domain} host" do
      host! host_for(domain)

      get developers_path

      assert_response :success
      assert_select "html[data-theme=#{theme}]"
    end
  end

  test "is edge-cacheable for a day" do
    host! host_for(:books)

    get developers_path

    assert_includes response.headers["Cache-Control"], "public"
    assert_includes response.headers["Cache-Control"], "max-age=86400"
  end

  # The page is served from the Cloudflare cache, so one per-visitor byte in it
  # is served to everyone. Compare the content this controller owns rather than
  # the whole body: the layout's csrf meta tag legitimately differs per session.
  test "renders identical content signed out and signed in" do
    host! host_for(:books)

    get developers_path
    signed_out = css_select("article#developers").to_s

    sign_in_as(users(:regular_user), stub_auth: true)
    get developers_path
    signed_in = css_select("article#developers").to_s

    assert_equal signed_out, signed_in
    refute_includes signed_in, users(:regular_user).email
  end

  test "documents the endpoints this host serves and only those" do
    host! host_for(:books)
    get developers_path
    assert_select "[id=?]", "endpoint-listBooks"
    assert_select "[id=?]", "endpoint-getBook"
    assert_select "[id=?]", "endpoint-listAuthors"
    assert_select "[id=?]", "endpoint-getAuthor"
    assert_select "[id=?]", "endpoint-getOpenapi"

    host! host_for(:music)
    get developers_path
    assert_select "[id=?]", "endpoint-getOpenapi"
    assert_select "[id=?]", "endpoint-listBooks", count: 0
    assert_select "[id=?]", "endpoint-listAuthors", count: 0
  end

  # Api::Problem#to_h points `type` at <host>/developers#errors-<code>. A code
  # without an anchor here is a dangling type URI on every error the API sends.
  test "has an anchor for every problem code" do
    host! host_for(:books)

    get developers_path

    Api::Problem::CODES.each do |code|
      assert_select "[id=?]", "errors-#{code}", 1
    end
  end

  test "links to the contract, the membership page and the token page" do
    host! host_for(:books)

    get developers_path

    assert_select "article#developers a[href=?]", "/api/v1/openapi.json"
    assert_select "article#developers a[href=?]", membership_path
    assert_select "article#developers a[href=?]", developers_tokens_path
  end

  test "the rate-limit table reads the configured limits" do
    host! host_for(:books)

    get developers_path

    limits = Rails.application.config.x.api.rate_limits
    assert_select "table#rate-limits-table td", text: limits.dig(:member, :per_minute).to_s
    assert_select "table#rate-limits-table td", text: limits.dig(:member, :per_day).to_s
    assert_select "table#rate-limits-table td", text: limits.dig(:system, :per_day).to_s
  end

  test "an unrepresentable format is a 404, not a 406" do
    host! host_for(:books)

    get "/developers.json"

    assert_response :not_found
  end
end
