# Base class for every mailer in the app.
#
# Subclasses call branded_mail, never mail, and always pass a domain. The domain
# is explicit because mailers are delivered from Sidekiq, where Current.domain
# is nil -- a mailer that reads Current sends books-branded mail to music
# subscribers, silently and unrecoverably.
class ApplicationMailer < ActionMailer::Base
  layout "mailer"

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
