require "test_helper"

class ApplicationMailerTest < ActionMailer::TestCase
  # Defined here rather than in app/ because it exists only to exercise the base
  # class. Renders inline, so it needs no view templates -- the shared layout
  # still wraps it, which is what the branding assertions below rely on.
  class ProbeMailer < ApplicationMailer
    def probe(domain:)
      branded_mail(domain: domain, to: "reader@example.org", subject: "Probe") do |format|
        format.text { render plain: "probe body", layout: "mailer" }
        format.html { render html: "<p>probe body</p>".html_safe, layout: "mailer" }
      end
    end
  end

  test "sets the from-address from the domain it was given" do
    with_env("MAIL_FROM_ADDRESS" => "noreply@example.org") do
      mail = ProbeMailer.probe(domain: :music)

      assert_equal ["noreply@example.org"], mail.from
      assert_equal "The Greatest Music <noreply@example.org>", mail[:from].value
    end
  end

  test "brands the mail for the domain it was given, not for Current.domain" do
    with_env("MAIL_FROM_ADDRESS" => "noreply@example.org") do
      Current.domain = :books
      mail = ProbeMailer.probe(domain: :games)

      assert_match "The Greatest Games", mail.body.encoded
      assert_no_match(/The Greatest Books/, mail.body.encoded)
    end
  ensure
    Current.domain = nil
  end

  test "brands the mail even when Current.domain is unset, as it is inside Sidekiq" do
    with_env("MAIL_FROM_ADDRESS" => "noreply@example.org") do
      Current.domain = nil
      mail = ProbeMailer.probe(domain: :music)

      assert_match "The Greatest Music", mail.body.encoded
    end
  end

  test "renders both an HTML and a plain-text part" do
    with_env("MAIL_FROM_ADDRESS" => "noreply@example.org") do
      mail = ProbeMailer.probe(domain: :books)

      assert_equal ["text/html", "text/plain"], mail.parts.map(&:mime_type).sort
    end
  end

  test "points link URLs at the host for that domain" do
    with_env("MAIL_FROM_ADDRESS" => "noreply@example.org") do
      mail = ProbeMailer.probe(domain: :games)
      expected_host = Rails.application.config.domains[:games].to_s.split(",").first

      assert_match expected_host, mail.body.encoded
    end
  end

  # Guards against `self.class.default_url_options =`: that form mutates a
  # class_attribute slot shared by every ProbeMailer instance -- across threads,
  # for the life of the process. Reproduced as a real cross-thread defect in
  # review (config/sidekiq.yml runs concurrency: 5, so concurrent delivery on
  # the same mailer subclass is this app's real configuration).
  #
  # Today's layout (@branding.root_url) always passes its host explicitly, so
  # body content never actually reads default_url_options -- a test asserting
  # on `mail.body.encoded` (or on `ApplicationMailer.default_url_options`, a
  # class the buggy write never touches -- it writes to the subclass actually
  # instantiated) passes against both the buggy and the fixed code and proves
  # nothing. This asserts directly on the class the buggy assignment mutates.
  test "does not leave default_url_options mutated on the mailer class after branded_mail runs" do
    with_env("MAIL_FROM_ADDRESS" => "noreply@example.org") do
      ProbeMailer.probe(domain: :books).message
      before = ProbeMailer.default_url_options

      ProbeMailer.probe(domain: :music).message

      assert_equal before, ProbeMailer.default_url_options
    end
  end

  # Drives the real deliver_later -> ActionMailer::MailDeliveryJob -> deliver_now
  # path (perform_enqueued_jobs, not a bare deliver_now call), because the
  # rescue_from's coverage of the actual SMTP round-trip -- as opposed to just
  # the mailer action body -- is exactly what Step 1 needed verified rather
  # than assumed. Stubs Mail::Message#deliver, the lowest-level call inside
  # that path, to simulate the SMTP failure itself.
  # A regression that interpolated error.message (or the recipient) into the
  # log line would pass "swallows ... instead of letting it raise" just as
  # easily as the fixed code -- that assertion only sees whether something
  # raised, not what got logged. This repo is public, and a real SMTP 550
  # quotes the rejected address back in its message, so the log line matters
  # as much as the non-raise. The rejected address below is deliberately
  # recognisable (not a generic string) so an interpolation regression can't
  # slip past by coincidence.
  test "swallows a permanent SMTP failure instead of letting it raise, and never logs the address or exception message" do
    with_env("MAIL_FROM_ADDRESS" => "noreply@example.org") do
      rejected_address = "nobody-rejected@example.org"
      smtp_error = Net::SMTPFatalError.new(
        "550 5.1.1 <#{rejected_address}>: Recipient address rejected: User unknown in virtual mailbox table"
      )
      Mail::Message.any_instance.stubs(:deliver).raises(smtp_error)

      log_output = StringIO.new
      original_logger = Rails.logger
      Rails.logger = Logger.new(log_output)

      begin
        assert_nothing_raised do
          perform_enqueued_jobs do
            ProbeMailer.probe(domain: :books).deliver_later
          end
        end
      ensure
        Rails.logger = original_logger
      end

      logged = log_output.string
      assert_includes logged, "#{ProbeMailer.mailer_name}#probe"
      assert_includes logged, "Net::SMTPFatalError"
      refute_includes logged, rejected_address
      refute_includes logged, smtp_error.message
    end
  end

  test "still raises a transient SMTP failure so Sidekiq retries it" do
    with_env("MAIL_FROM_ADDRESS" => "noreply@example.org") do
      Mail::Message.any_instance.stubs(:deliver).raises(Net::SMTPServerBusy.new("421 too busy"))

      # assert_raises has to sit INSIDE perform_enqueued_jobs's block, not
      # around the whole call: perform_enqueued_jobs itself wraps its block in
      # assert_nothing_raised, which repackages any escaping exception as a
      # Minitest::UnexpectedError -- a class assert_raises(Net::SMTPServerBusy)
      # would never match, so it would misreport as an unrelated Error instead
      # of confirming the real exception propagated. This is what
      # perform_enqueued_jobs's own warning message ("use assert_raises as
      # near to the code that raises as possible") is telling you to do.
      perform_enqueued_jobs do
        assert_raises(Net::SMTPServerBusy) do
          ProbeMailer.probe(domain: :books).deliver_later
        end
      end
    end
  end
end
