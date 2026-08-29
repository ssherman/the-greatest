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

  test "new_correction goes to the admin address" do
    mail = AdminMailer.new_correction(corrections(:war_and_peace_pending))

    assert_equal ["owner@example.org"], mail.to
    # Case-insensitive: the subject follows this mailer's existing sentence-case
    # convention ("New membership on...", "New donation:...") -- "New correction
    # on...", lowercase c -- so a case-sensitive /Correction/ never matches it.
    assert_match(/Correction/i, mail.subject)
  end

  test "new_correction is branded for the record's domain" do
    mail = AdminMailer.new_correction(corrections(:war_and_peace_pending))

    assert_match(/The Greatest Books/, mail[:from].to_s)
  end

  # Books is MailBranding's DEFAULT_DOMAIN fallback, so the test above alone
  # cannot tell a correctly-resolved books domain from a resolution that fell
  # through to nil -- it would pass either way. A music correction has no such
  # cover: if TypeRegistry.domain_for silently returned nil here, MailBranding
  # would fall back to books branding and this assertion would catch it.
  test "new_correction is branded for a music record's domain, not books' fallback branding" do
    mail = AdminMailer.new_correction(corrections(:dark_side_pending))

    assert_match(/The Greatest Music/, mail[:from].to_s)
    assert_no_match(/The Greatest Books/, mail[:from].to_s)
    # admin_correction_url, not admin_books_correction_url -- music's admin
    # namespace has no domain infix (see Admin::CorrectionsController::ADMIN_PATHS).
    assert_match(%r{//dev\.thegreatestmusic\.org(:\d+)?/admin/corrections/\d+}, mail.body.encoded)
  end

  test "new_correction replies to a signed-in submitter" do
    mail = AdminMailer.new_correction(corrections(:war_and_peace_pending))

    assert_equal [users(:regular_user).email], mail.reply_to
  end

  test "new_correction sets no reply_to for an anonymous submitter" do
    mail = AdminMailer.new_correction(corrections(:war_and_peace_notes_only))

    assert_nil mail.reply_to
  end

  test "new_correction includes the notes and the proposed fields" do
    mail = AdminMailer.new_correction(corrections(:war_and_peace_pending))
    body = mail.text_part.body.to_s

    assert_match(/first published year/i, body)
    assert_match(/1867/, body)
    assert_match(/The first published year looks wrong/, body)
  end

  test "contact_message goes to the public contact address" do
    mail = AdminMailer.contact_message(contact_messages(:books_pending))

    assert_equal [SiteContact::ADDRESS], mail.to
  end

  test "contact_message names the site in the subject" do
    mail = AdminMailer.contact_message(contact_messages(:books_pending))

    assert_match(/The Greatest Books/, mail.subject)
  end

  test "contact_message replies to the sender" do
    message = contact_messages(:books_anonymous)
    mail = AdminMailer.contact_message(message)

    assert_equal [message.email], mail.reply_to
  end

  # Books is MailBranding's DEFAULT_DOMAIN fallback, so a books-only assertion
  # cannot tell a resolved domain from one that fell through to nil. A music
  # message has no such cover.
  test "contact_message is branded for a music message, not books' fallback" do
    mail = AdminMailer.contact_message(contact_messages(:music_pending))

    assert_match(/The Greatest Music/, mail[:from].to_s)
    assert_no_match(/The Greatest Books/, mail[:from].to_s)
  end

  test "contact_message includes the message body" do
    message = contact_messages(:books_anonymous)
    mail = AdminMailer.contact_message(message)

    assert_match(/RSS feed/, mail.text_part.body.to_s)
  end
end
