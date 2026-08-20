# Operational mail. Not customer-facing.
class SystemMailer < ApplicationMailer
  # Sent by `rake mail:smoke`. The only way to verify SendGrid credentials,
  # domain authentication and queue wiring in an environment without waiting for
  # a real customer email to fail.
  def smoke_test(domain:, to:)
    @sent_at = Time.current

    branded_mail(domain: domain, to: to, subject: "Mail smoke test — #{Rails.env}")
  end
end
