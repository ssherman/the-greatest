# frozen_string_literal: true

require "test_helper"
require Rails.root.join("config/host_allowlist").to_s

# config.hosts is set only in production (config/initializers/host_authorization.rb),
# so no integration test ever runs behind it. These run the real
# ActionDispatch::HostAuthorization middleware with exactly what that
# initializer hands it.
class HostAllowlistTest < ActiveSupport::TestCase
  DOMAINS = {
    music: "music.example",
    games: "games.example,www.games.example",
    books: "books.example"
  }.freeze

  def status_for(host, path = "/", headers = {}, domains: DOMAINS)
    app = ->(_env) { [200, {}, ["ok"]] }
    middleware = ActionDispatch::HostAuthorization.new(app, HostAllowlist.hosts(domains), **HostAllowlist.authorization)
    middleware.call(Rack::MockRequest.env_for(path, {"HTTP_HOST" => host}.merge(headers))).first
  end

  test "admits every configured host, including each entry of a comma-separated value" do
    %w[music.example games.example www.games.example books.example].each do |host|
      assert_equal 200, status_for(host), host
    end
  end

  test "admits the hosts this environment's routes serve" do
    %w[dev.thegreatestmusic.org dev.thegreatest.games dev-new.thegreatestbooks.org].each do |host|
      assert_equal 200, status_for(host, domains: Rails.application.config.domains), host
    end
  end

  test "refuses an unknown host" do
    assert_equal 403, status_for("evil.example")
  end

  test "a forged X-Forwarded-Host is refused even behind a configured Host" do
    assert_equal 403, status_for("music.example", "/", {"HTTP_X_FORWARDED_HOST" => "evil.example"})
  end

  # docker-compose.prod.yml's healthcheck curls http://localhost:3000/up.
  test "the health check is admitted from any host" do
    assert_equal 200, status_for("localhost:3000", "/up")
  end

  test "only /up itself is exempt" do
    assert_equal 403, status_for("evil.example", "/upload")
    assert_equal 403, status_for("evil.example", "/up/anything")
  end

  test "refuses a config.domains that yields no hosts" do
    assert_raises(ArgumentError) { HostAllowlist.hosts({music: "", books: ""}) }
  end
end
