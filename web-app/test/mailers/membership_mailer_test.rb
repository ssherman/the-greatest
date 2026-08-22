require "test_helper"

class MembershipMailerTest < ActionMailer::TestCase
  setup { ENV["MAIL_FROM_ADDRESS"] = "contact@example.org" }
  teardown { ENV.delete("MAIL_FROM_ADDRESS") }

  test "addresses the welcome email to the member" do
    membership = memberships(:regular_user_monthly)
    mail = MembershipMailer.welcome(membership)

    assert_equal [membership.user.email], mail.to
    assert_equal ["contact@example.org"], mail.from
  end

  # The whole reason branded_mail takes a domain explicitly: this runs in
  # Sidekiq, where Current.domain is nil.
  test "brands the welcome email for the membership's own origin_domain" do
    membership = memberships(:regular_user_monthly)
    membership.update!(origin_domain: "music")

    mail = MembershipMailer.welcome(membership)

    assert_match "The Greatest Music", mail.body.encoded
    assert_no_match(/The Greatest Books/, mail.body.encoded)
  end

  test "links to the membership page on that same site, not to a hardcoded Stripe URL" do
    membership = memberships(:regular_user_monthly)
    membership.update!(origin_domain: "games")
    games_host = Rails.application.config.domains[:games].to_s.split(",").first

    mail = MembershipMailer.welcome(membership)

    assert_match games_host, mail.body.encoded
    assert_match "/membership", mail.body.encoded
    assert_no_match(/billing\.stripe\.com/, mail.body.encoded)
  end

  test "renders both an HTML and a plain-text part" do
    mail = MembershipMailer.welcome(memberships(:regular_user_monthly))

    assert_equal ["text/html", "text/plain"], mail.parts.map(&:mime_type).sort
  end

  test "the cancelled-last email says access ends and names the date" do
    membership = memberships(:regular_user_monthly)
    membership.update!(status: :canceled, current_period_end: 30.days.from_now, origin_domain: "books")

    mail = MembershipMailer.canceled_last(membership)

    assert_equal [membership.user.email], mail.to
    assert_match membership.current_period_end.strftime("%B %-d, %Y"), mail.body.encoded
  end

  test "the cancelled-with-other-active email does not claim access is ending" do
    membership = memberships(:regular_user_monthly)
    membership.update!(status: :canceled, current_period_end: 30.days.from_now, origin_domain: "books")

    mail = MembershipMailer.canceled_with_other_active(membership)

    assert_equal [membership.user.email], mail.to
    assert_no_match(/revert to a free account/, mail.body.encoded)
  end
end
