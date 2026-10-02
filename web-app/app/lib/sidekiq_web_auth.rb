# frozen_string_literal: true

# The Basic-auth check in front of Sidekiq::Web (config/routes.rb).
#
# Fails closed: if either expected credential is blank, nothing gets in. The
# previous inline check compared against ENV[...].to_s, so with the variables
# unset an empty username and password passed (security audit M2). It fails
# at request time, not at boot, so a missing variable locks the dashboard
# rather than taking the site down.
#
# Both sides are SHA-256'd before secure_compare so the comparison is
# constant-time regardless of input length.
module SidekiqWebAuth
  def self.authenticate(username, password,
    expected_username: ENV["SIDEKIQ_ADMIN_USERNAME"],
    expected_password: ENV["SIDEKIQ_ADMIN_PASSWORD"])
    return false if expected_username.blank? || expected_password.blank?

    matches?(username, expected_username) & matches?(password, expected_password)
  end

  def self.matches?(given, expected)
    ActiveSupport::SecurityUtils.secure_compare(
      ::Digest::SHA256.hexdigest(given.to_s),
      ::Digest::SHA256.hexdigest(expected)
    )
  end
  private_class_method :matches?
end
