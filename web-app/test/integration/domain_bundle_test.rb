# frozen_string_literal: true

require "test_helper"

# The lint guard in test/lint/asset_bundle_coverage_test.rb reads layout SOURCE.
# This checks the other half: that a real request on each host resolves
# domain_js_bundle to that domain's bundle and Propshaft can find it.
#
# Asserts on the script src path only -- behaviour, not markup. A designer
# reshaping these layouts must not break this test.
#
# Requires built bundles on disk, so run via `bin/rails db:test:prepare test`
# (which builds) rather than plain `bin/rails test` (which does not).
class DomainBundleTest < ActionDispatch::IntegrationTest
  HOSTS = {
    "books" => "dev-new.thegreatestbooks.org",
    "music" => "dev.thegreatestmusic.org",
    "games" => "dev.thegreatest.games"
  }.freeze

  HOSTS.each do |domain, hostname|
    test "#{domain} pages load the #{domain}-web bundle" do
      host! hostname
      get public_send("#{domain}_root_path")
      assert_response :success

      sources = Nokogiri::HTML5(response.body).css("script[src]").map { |node| node["src"] }

      assert sources.any? { |src| src.include?("#{domain}-web") },
        "Expected a script tag for the #{domain}-web bundle on #{hostname}, got: #{sources.inspect}"

      (HOSTS.keys - [domain]).each do |other|
        refute sources.any? { |src| src.include?("#{other}-web") },
          "#{hostname} loaded the #{other}-web bundle. Domain bundles must not cross sites."
      end
    end
  end
end
