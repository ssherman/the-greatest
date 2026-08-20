require "test_helper"

class MailBrandingTest < ActiveSupport::TestCase
  test "resolves the site name for each domain" do
    assert_equal "The Greatest Books", MailBranding.for(:books).site_name
    assert_equal "The Greatest Music", MailBranding.for(:music).site_name
    assert_equal "The Greatest Games", MailBranding.for(:games).site_name
  end

  test "accepts a string domain, as stored in memberships.origin_domain" do
    assert_equal :music, MailBranding.for("music").key
    assert_equal "The Greatest Music", MailBranding.for("music").site_name
  end

  # Every membership created before checkout existed -- including every row from
  # the account-wide migration -- has origin_domain: nil. The mailers must not
  # blow up on those, and must not send an unbranded email either.
  test "falls back to books for a nil domain" do
    assert_equal :books, MailBranding.for(nil).key
    assert_equal "The Greatest Books", MailBranding.for(nil).site_name
  end

  test "falls back to books for a domain with no mail identity" do
    assert_equal :books, MailBranding.for(:nonexistent).key
  end

  test "builds a from-address combining the site name and the ENV address" do
    with_env("MAIL_FROM_ADDRESS" => "noreply@example.org") do
      assert_equal "The Greatest Music <noreply@example.org>", MailBranding.for(:music).from
    end
  end

  test "raises rather than sending from a malformed address when MAIL_FROM_ADDRESS is unset" do
    with_env("MAIL_FROM_ADDRESS" => nil) do
      error = assert_raises(MailBranding::MissingFromAddress) { MailBranding.for(:books).from }
      assert_match "MAIL_FROM_ADDRESS", error.message
    end
  end

  # config.domains values come from ENV and may hold a comma-separated list --
  # the same reason MembershipController#canonical_host splits on ",". A URL
  # host of "a.example.org,b.example.org" produces links that 404.
  test "uses only the first host when the configured domain is a comma-separated list" do
    original = Rails.application.config.domains[:books]
    Rails.application.config.domains[:books] = "first.example.org,second.example.org"

    assert_equal "first.example.org", MailBranding.for(:books).url_options[:host]
  ensure
    Rails.application.config.domains[:books] = original
  end

  test "url_options carry a protocol" do
    assert_includes %w[http https], MailBranding.for(:books).url_options[:protocol]
  end

  # The site name has exactly one home: config.domain_settings. Duplicating it
  # into the mailer layer guarantees the two copies drift.
  test "reads the site name from domain_settings rather than a second copy" do
    original = Rails.application.config.domain_settings[:books]
    Rails.application.config.domain_settings[:books] = original.merge(name: "Renamed Site")

    assert_equal "Renamed Site", MailBranding.for(:books).site_name
  ensure
    Rails.application.config.domain_settings[:books] = original
  end

  test "each supported domain has a distinct brand colour in hex, not oklch" do
    colors = [:books, :music, :games].map { |domain| MailBranding.for(domain).brand_color }

    assert_equal colors.uniq.length, colors.length, "brand colours must be distinguishable"
    colors.each { |color| assert_match(/\A#[0-9A-F]{6}\z/, color, "email clients cannot parse oklch()") }
  end

  # There is no bare root_url helper in this app -- each domain's root route is
  # separately named, because four sites share one route file.
  #
  # NOTE: which helper ROOT_HELPERS picks is deliberately NOT asserted here.
  # All three root routes map to "/", and the host comes from url_options, so a
  # wrong mapping (books -> :music_root_url) produces a byte-identical URL and
  # no behavioural test can distinguish it. Asserting the constant's contents
  # would test the implementation, not the behaviour. This becomes testable the
  # day any domain's root moves off "/" -- add the assertion then.
  test "builds a root URL on the right host for each domain" do
    [:books, :music, :games].each do |domain|
      branding = MailBranding.for(domain)
      expected_host = Rails.application.config.domains[domain].to_s.split(",").first

      assert_includes branding.root_url, expected_host
    end
  end
end
