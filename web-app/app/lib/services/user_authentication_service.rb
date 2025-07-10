# Service for finding or creating a user from provider data
module Services
  class UserAuthenticationService
    def self.call(provider_data:)
      # Extract user information from provider data
      email = provider_data[:email]
      uid = provider_data[:user_id]
      name = provider_data[:name]
      photo_url = provider_data[:picture]
      provider = provider_data[:provider]
      raise ArgumentError, "provider is required in provider_data" if provider.nil?

      # Find user by email first, then by auth_uid
      user = User.find_by("LOWER(email) = ?", email.downcase) if email
      user ||= User.find_by(auth_uid: uid) if uid

      if user.nil?
        # Create new user
        user = User.new(
          email: email,
          auth_uid: uid,
          display_name: name,
          photo_url: photo_url,
          external_provider: provider,
          email_verified: provider_data[:email_verified] || false,
          role: :user,
          last_sign_in_at: Time.current,
          sign_in_count: 1
        )
      else
        # Update existing user (don't change email)
        user.update!(
          auth_uid: uid,
          display_name: name,
          photo_url: photo_url,
          external_provider: provider,
          email_verified: provider_data[:email_verified] || user.email_verified,
          last_sign_in_at: Time.current,
          sign_in_count: (user.sign_in_count || 0) + 1
        )
      end

      # Store provider data
      user.provider_data ||= {}
      user.provider_data[provider.to_s] = provider_data
      user.save!

      user
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error "Failed to create/update user: #{e.message}"
      raise e
    end
  end
end
