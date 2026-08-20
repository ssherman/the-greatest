require "test_helper"

class MailDeliverySettingsTest < ActiveSupport::TestCase
  test "builds SendGrid SMTP settings with the API key from ENV" do
    with_env("SENDGRID_API_KEY" => "SG.a-real-looking-key") do
      settings = MailDeliverySettings.sendgrid_smtp

      assert_equal "smtp.sendgrid.net", settings[:address]
      assert_equal 587, settings[:port]
      assert_equal "SG.a-real-looking-key", settings[:password]
      assert_equal :plain, settings[:authentication]
      assert settings[:enable_starttls_auto]
    end
  end

  # SendGrid's SMTP username is the literal string "apikey" for every account --
  # it is not the account name. Getting this wrong authenticates as nobody and
  # every send fails with a 535.
  test "the SMTP username is the literal string apikey, not the key itself" do
    with_env("SENDGRID_API_KEY" => "SG.some-key") do
      assert_equal "apikey", MailDeliverySettings.sendgrid_smtp[:user_name]
    end
  end

  test "raises rather than substituting a placeholder when the API key is missing" do
    with_env("SENDGRID_API_KEY" => nil) do
      error = assert_raises(MailDeliverySettings::MissingApiKey) do
        MailDeliverySettings.sendgrid_smtp
      end
      # The message must name the variable but must never echo a value.
      assert_match "SENDGRID_API_KEY", error.message
    end
  end

  test "raises when the API key is present but blank" do
    with_env("SENDGRID_API_KEY" => "   ") do
      assert_raises(MailDeliverySettings::MissingApiKey) { MailDeliverySettings.sendgrid_smtp }
    end
  end
end
