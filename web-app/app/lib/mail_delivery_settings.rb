# Builds the SMTP settings ActionMailer needs to talk to SendGrid.
#
# This exists so that exactly one place reads SENDGRID_API_KEY. Environment
# files call it; nothing else should.
#
# It raises rather than falling back to a default. A placeholder key would let
# the app boot and then fail every send with an opaque 535 from SendGrid -- or,
# if the placeholder were ever a real key, send mail from the wrong account.
class MailDeliverySettings
  class MissingApiKey < StandardError; end

  # SendGrid authenticates SMTP with the literal username "apikey" and the API
  # key as the password. Same for every account -- it is not the account's
  # username.
  SMTP_USER_NAME = "apikey"
  SMTP_ADDRESS = "smtp.sendgrid.net"
  SMTP_PORT = 587

  def self.sendgrid_smtp
    api_key = ENV["SENDGRID_API_KEY"]

    if api_key.blank?
      raise MissingApiKey, "SENDGRID_API_KEY is not set; refusing to build SMTP settings"
    end

    {
      address: SMTP_ADDRESS,
      port: SMTP_PORT,
      domain: ENV.fetch("BOOKS_DOMAIN", "thegreatestbooks.org"),
      user_name: SMTP_USER_NAME,
      password: api_key,
      authentication: :plain,
      enable_starttls_auto: true
    }
  end
end
