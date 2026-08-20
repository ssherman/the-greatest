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

  setup { ENV["MAIL_FROM_ADDRESS"] = "noreply@example.org" }
  teardown { ENV.delete("MAIL_FROM_ADDRESS") }

  test "sets the from-address from the domain it was given" do
    mail = ProbeMailer.probe(domain: :music)

    assert_equal ["noreply@example.org"], mail.from
    assert_equal "The Greatest Music <noreply@example.org>", mail[:from].value
  end

  test "brands the mail for the domain it was given, not for Current.domain" do
    Current.domain = :books
    mail = ProbeMailer.probe(domain: :games)

    assert_match "The Greatest Games", mail.body.encoded
    assert_no_match(/The Greatest Books/, mail.body.encoded)
  ensure
    Current.domain = nil
  end

  test "brands the mail even when Current.domain is unset, as it is inside Sidekiq" do
    Current.domain = nil
    mail = ProbeMailer.probe(domain: :music)

    assert_match "The Greatest Music", mail.body.encoded
  end

  test "renders both an HTML and a plain-text part" do
    mail = ProbeMailer.probe(domain: :books)

    assert_equal ["text/html", "text/plain"], mail.parts.map(&:mime_type).sort
  end

  test "points link URLs at the host for that domain" do
    mail = ProbeMailer.probe(domain: :games)
    expected_host = Rails.application.config.domains[:games].to_s.split(",").first

    assert_match expected_host, mail.body.encoded
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
    ProbeMailer.probe(domain: :books).message
    before = ProbeMailer.default_url_options

    ProbeMailer.probe(domain: :music).message

    assert_equal before, ProbeMailer.default_url_options
  end
end
