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

  test "new_list_submission is addressed to the admin and names the list" do
    list = Books::List.create!(name: "Greatest Books Ever", status: :unapproved,
      submitted_at: Time.current, url: "https://example.com/greatest")

    mail = AdminMailer.new_list_submission(list)

    assert_equal [ENV["ADMIN_NOTIFICATION_EMAIL"]], mail.to
    assert_match "Greatest Books Ever", mail.subject
    assert_match "Greatest Books Ever", mail.body.encoded
  end

  test "new_list_submission replies to a signed-in submitter" do
    user = users(:regular_user)
    list = Books::List.create!(name: "With account", status: :unapproved,
      submitted_at: Time.current, submitted_by: user)

    mail = AdminMailer.new_list_submission(list)

    assert_equal [user.email], mail.reply_to
  end

  test "new_list_submission replies to an anonymous submitted email" do
    list = Books::List.create!(name: "Anon with email", status: :unapproved,
      submitted_at: Time.current, submitter_email: "reader@example.com")

    mail = AdminMailer.new_list_submission(list)

    assert_equal ["reader@example.com"], mail.reply_to
  end

  test "new_list_submission has no reply_to for a fully anonymous submission" do
    list = Books::List.create!(name: "Fully anon", status: :unapproved,
      submitted_at: Time.current)

    mail = AdminMailer.new_list_submission(list)

    assert_nil mail.reply_to
  end

  # submitter_email is anonymous, unvalidated input capped only at 255 chars --
  # a value that isn't a parseable address would otherwise be emitted raw into
  # Reply-To: and risk SendGrid rejecting the whole owner notification.
  test "new_list_submission has no reply_to for an unparseable submitter email" do
    list = Books::List.create!(name: "Not an email", status: :unapproved,
      submitted_at: Time.current, submitter_email: "not an email")

    mail = AdminMailer.new_list_submission(list)

    assert_nil mail.reply_to
  end

  # list.submitter_email is attacker-controlled, unvalidated public input --
  # List has no format validation on it (app/models/list.rb) and the submission
  # service caps only its length -- and new_list_submission puts it straight
  # into reply_to:. This pins that an embedded CR/LF can never terminate the
  # Reply-To header and start a new one (a Bcc:, a second Subject:, ...).
  #
  # Confirmed empirically before writing this: the Mail gem quoted-printable
  # -encodes a header value containing control characters instead of emitting
  # them raw, so a literal LF/CRLF here reaches the wire as the literal
  # characters "=0A"/"=0D=0A" -- never as an actual line break. Both hostile
  # shapes below produced that encoding; if the gem's behaviour ever changes
  # this test fails and reply_to needs an address-format guard before use.
  test "an embedded LF in submitter_email cannot inject a Bcc header" do
    list = Books::List.create!(name: "Hostile LF", status: :unapproved,
      submitted_at: Time.current, submitter_email: "a@b.com\nBcc: victim@example.com")

    mail = AdminMailer.new_list_submission(list)
    header_section = mail.encoded[0...mail.encoded.index("\r\n\r\n")]

    refute_match(/^Bcc:/i, header_section)
  end

  test "an embedded CRLF in submitter_email cannot inject a second Subject header" do
    list = Books::List.create!(name: "Hostile CRLF", status: :unapproved,
      submitted_at: Time.current, submitter_email: "a@b.com\r\nSubject: spam")

    mail = AdminMailer.new_list_submission(list)
    header_section = mail.encoded[0...mail.encoded.index("\r\n\r\n")]

    assert_equal 1, header_section.scan(/^Subject:/i).count
  end
end
