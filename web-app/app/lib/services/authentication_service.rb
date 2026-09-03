# Main authentication orchestrator.
#
# Everything this returns is derived from a signature-verified token. Nothing
# reaches it from request params. That is the entire security property: the
# previous version preferred params[:user_data]'s email over the signed `email`
# claim and took the provider from params[:provider], so a caller holding a
# valid token for their own account could name any victim and be handed that
# victim's row.
module Services
  class AuthenticationService
    # Firebase's sign_in_provider values, mapped to User#external_provider.
    # Firebase suffixes OAuth providers with ".com" but uses a bare "password"
    # for email/password. Anything absent here (anonymous, custom) is a provider
    # this app does not model and must not authenticate.
    PROVIDER_MAP = {
      "password" => "password",
      "google.com" => "google",
      "apple.com" => "apple",
      "facebook.com" => "facebook",
      "twitter.com" => "twitter"
    }.freeze

    def self.call(auth_token:, project_id:, signup_domain: nil)
      payload = JwtValidationService.call(auth_token, project_id: project_id)
      provider_data = extract_provider_data(payload)

      user = UserAuthenticationService.call(
        provider_data: provider_data,
        signup_domain: signup_domain
      )

      {success: true, user: user, provider_data: provider_data}
    rescue JWT::DecodeError => e
      Rails.logger.warn "JWT validation failed: #{e.class}"
      {success: false, error: "Invalid authentication token", error_code: :invalid_token}
    rescue UnsupportedProviderError => e
      Rails.logger.warn "Unsupported sign-in provider: #{e.message}"
      {success: false, error: "This sign-in method is not supported", error_code: :unsupported_provider}
    rescue UserAuthenticationService::UnverifiedEmailConflict
      {
        success: false,
        error: "Please verify your email address, then sign in again.",
        error_code: :email_verification_required
      }
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error "User creation/update failed: #{e.message}"
      {success: false, error: "Failed to create user account", error_code: :user_creation_failed}
    rescue => e
      Rails.logger.error "Authentication failed: #{e.class}: #{e.message}"
      {success: false, error: "Authentication failed", error_code: :authentication_failed}
    end

    class UnsupportedProviderError < StandardError; end

    # No logging of the payload here. It used to write the full identity payload
    # -- email included -- to production logs at info level.
    def self.extract_provider_data(payload)
      sign_in_provider = payload.dig("firebase", "sign_in_provider")
      provider = PROVIDER_MAP[sign_in_provider]
      raise UnsupportedProviderError, sign_in_provider.inspect if provider.nil?

      {
        user_id: payload["sub"],
        email: payload["email"],
        name: payload["name"],
        picture: payload["picture"],
        # Strict true: Firebase sends a real boolean, and `|| false` on a
        # missing claim must not become "verified".
        email_verified: payload["email_verified"] == true,
        provider: provider,
        auth_time: payload["auth_time"],
        iat: payload["iat"],
        exp: payload["exp"]
      }
    end

    private_class_method :extract_provider_data
  end
end
