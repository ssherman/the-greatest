# Base class for every mailer in the app.
#
# Subclasses call branded_mail, never mail, and always pass a domain. The domain
# is explicit because mailers are delivered from Sidekiq, where Current.domain
# is nil -- a mailer that reads Current sends books-branded mail to music
# subscribers, silently and unrecoverably.
class ApplicationMailer < ActionMailer::Base
  layout "mailer"

  # A permanent SMTP failure (550 mailbox unavailable, 553 bad address) will
  # never succeed on retry, and raise_delivery_errors is on in production -- so
  # without this, one dead mailbox burns 25 Sidekiq retries over ~21 days. A
  # transient failure (e.g. Net::SMTPServerBusy) raises a different class and
  # still retries normally.
  #
  # Verified this covers the actual delivery path, not just the mailer action
  # body, before shipping it -- an earlier increment on this branch learned
  # the hard way that a plan's prescribed one-liner can compile and still be
  # wrong for this Rails version. deliver_later's job (MailDeliveryJob) calls
  # message_delivery.deliver_now, which wraps BOTH the mailer action AND the
  # actual message.deliver call in the same mailer *instance*'s
  # handle_exceptions -- so a rescue_from registered here fires for a raise
  # from the real SMTP round-trip, with mailer_name/action_name available as
  # ordinary instance methods (confirmed empirically: driving
  # ActionMailer::MailDeliveryJob#perform_now with message.deliver stubbed to
  # raise). See application_mailer_test.rb for the regression test.
  #
  # Logs the mailer and action only. Never the recipient, never the exception
  # message: this repo is public and an SMTP error message quotes the address
  # it rejected.
  rescue_from Net::SMTPFatalError, Net::SMTPSyntaxError do |error|
    Rails.logger.warn(
      "Permanent delivery failure for #{mailer_name}##{action_name} (#{error.class}); not retrying"
    )
  end

  private

  # @param domain [Symbol, String, nil] which site this mail is about. nil is
  #   valid and falls back to books -- see MailBranding.
  def branded_mail(domain:, **options, &block)
    @branding = MailBranding.for(domain)
    # self., not self.class. -- default_url_options is a class_attribute, so a
    # class-level write here would mutate state shared by every instance and
    # every thread of this mailer subclass. See ApplicationMailerTest's
    # "does not leave default_url_options mutated..." test.
    self.default_url_options = @branding.url_options

    mail(options.merge(from: @branding.from), &block)
  end
end
