# Main authentication orchestrator
module Services
  class AuthenticationService
    def self.call(auth_token:, provider:, project_id: nil, user_data: nil)
      # Validate the JWT token
      payload = JwtValidationService.call(auth_token, project_id: project_id)

      # Extract user data from user_data parameter or fallback to JWT payload
      provider_data = extract_provider_data(payload, provider, user_data)

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

    def self.extract_provider_data(payload, provider, user_data = nil)
      # Debug: Log the full payload to see what's available
      Rails.logger.info "JWT Payload: #{payload.inspect}"
      Rails.logger.info "User Data: #{user_data.inspect}" if user_data

      # Extract email from user_data if available
      email = nil
      if user_data&.dig("providerData")&.any?
        provider_data = user_data["providerData"].find { |p| p["providerId"] == "#{provider}.com" }
        email = provider_data["email"] if provider_data
      end

      # Fallback to JWT payload if no email found in user_data
      email ||= payload["email"]

      {
        user_id: payload["sub"],
        email: email,
        name: payload["name"] || user_data&.dig("displayName"),
        picture: payload["picture"] || user_data&.dig("photoURL"),
        email_verified: payload["email_verified"] || user_data&.dig("emailVerified") || false,
        provider: provider,
        auth_time: payload["auth_time"],
        iat: payload["iat"],
        exp: payload["exp"]
      }
    end

    private_class_method :extract_provider_data
  end
end
