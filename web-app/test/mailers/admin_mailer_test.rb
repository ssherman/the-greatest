require "test_helper"

class AdminMailerTest < ActionMailer::TestCase
  setup do
    ENV["MAIL_FROM_ADDRESS"] = "contact@example.org"
    ENV["ADMIN_NOTIFICATION_EMAIL"] = "owner@example.org"
  end

  teardown do
    ENV.delete("MAIL_FROM_ADDRESS")
    ENV.delete("ADMIN_NOTIFICATION_EMAIL")
  end

  test "new_subscription goes to the admin address, not to the member" do
    membership = memberships(:regular_user_monthly)
    membership.update!(origin_domain: "music")

    mail = AdminMailer.new_subscription(membership)

    assert_equal ["owner@example.org"], mail.to
    assert_no_match(/#{Regexp.escape(membership.user.email)}/, mail.subject)
  end

  test "new_subscription names which site the sale came from" do
    membership = memberships(:regular_user_monthly)
    membership.update!(origin_domain: "games")

    mail = AdminMailer.new_subscription(membership)

    assert_match "The Greatest Games", mail.body.encoded
  end

  test "subscription_canceled goes to the admin address, not to the member" do
    membership = memberships(:regular_user_monthly)
    membership.update!(origin_domain: "music")

    mail = AdminMailer.subscription_canceled(membership)

    assert_equal ["owner@example.org"], mail.to
    assert_no_match(/#{Regexp.escape(membership.user.email)}/, mail.subject)
  end

  test "subscription_canceled names which site the membership was on" do
    membership = memberships(:regular_user_monthly)
    membership.update!(origin_domain: "games")

    mail = AdminMailer.subscription_canceled(membership)

    assert_match "The Greatest Games", mail.body.encoded
  end

  test "new_donation names the amount" do
    donation = donations(:regular_user_gift)
    donation.update!(amount_cents: 5000, domain: "books")

    mail = AdminMailer.new_donation(donation)

    assert_equal ["owner@example.org"], mail.to
    assert_match "$50.00", mail.body.encoded
  end

  test "anonymous_donation does not assume a user" do
    donation = donations(:regular_user_gift)
    donation.update!(user: nil, email: nil, amount_cents: 1000, domain: "books")

    mail = AdminMailer.anonymous_donation(donation)

    assert_equal ["owner@example.org"], mail.to
    assert_match "$10.00", mail.body.encoded
  end

  test "raises nothing useful-looking when ADMIN_NOTIFICATION_EMAIL is unset" do
    ENV.delete("ADMIN_NOTIFICATION_EMAIL")

    assert_raises(AdminMailer::MissingAdminAddress) do
      AdminMailer.new_subscription(memberships(:regular_user_monthly)).to
    end
  end
end
