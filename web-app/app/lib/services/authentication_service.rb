# Main authentication orchestrator
class AuthenticationService
  def self.call(auth_token:, provider:, project_id: nil)
    # Validate the JWT token
    payload = JwtValidationService.call(auth_token, project_id: project_id)

    # Extract user data from the payload
    provider_data = extract_provider_data(payload, provider)

    # Find or create the user
    user = UserAuthenticationService.call(provider_data: provider_data)

    # Return success result
    {
      success: true,
      user: user,
      provider_data: provider_data
    }
  rescue JWT::DecodeError => e
    Rails.logger.error "JWT validation failed: #{e.message}"
    {
      success: false,
      error: "Invalid authentication token",
      error_code: :invalid_token
    }
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.error "User creation/update failed: #{e.message}"
    {
      success: false,
      error: "Failed to create user account",
      error_code: :user_creation_failed
    }
  rescue => e
    Rails.logger.error "Authentication failed: #{e.message}"
    {
      success: false,
      error: "Authentication failed",
      error_code: :authentication_failed
    }
  end

  def self.extract_provider_data(payload, provider)
    {
      user_id: payload["sub"],
      email: payload["email"],
      name: payload["name"],
      picture: payload["picture"],
      email_verified: payload["email_verified"],
      provider: provider,
      auth_time: payload["auth_time"],
      iat: payload["iat"],
      exp: payload["exp"]
    }
  end

  private_class_method :extract_provider_data
end
