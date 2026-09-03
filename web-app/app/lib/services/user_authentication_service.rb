# Finds or creates the User a verified Firebase token belongs to.
#
# The lookup order is the security boundary:
#
#   1. auth_uid == the token's `sub`. Exact, and it came out of a signature.
#   2. a VERIFIED email. Control of an address proves ownership of the account
#      that uses it, so this relinks -- a V1 user imported under one uid who
#      later signs in with Google presents a different sub, and refusing would
#      lock them out of their own data.
#   3. an UNVERIFIED email that matches an existing account is refused outright.
#      This is the takeover route: anyone can create a Firebase password account
#      for someone else's address, and the previous version matched on email
#      unconditionally and then update!'d that row.
#   4. otherwise, create.
module Services
  class UserAuthenticationService
    # Raised at step 3. Callers turn this into "verify your email, then sign in
    # again" -- never into a new account, and never into a link.
    class UnverifiedEmailConflict < StandardError; end

    def self.call(provider_data:, signup_domain: nil)
      new(provider_data, signup_domain).call
    end

    def initialize(provider_data, signup_domain = nil)
      @provider_data = provider_data
      @signup_domain = signup_domain
    end

    def call
      raise ArgumentError, "provider is required in provider_data" if provider.blank?
      raise ArgumentError, "user_id is required in provider_data" if uid.blank?

      user = find_user
      user ? update_existing(user) : build_new
    end

    private

    attr_reader :provider_data, :signup_domain

    def uid = provider_data[:user_id]
    def provider = provider_data[:provider]
    def email = provider_data[:email].presence&.downcase
    def email_verified? = provider_data[:email_verified] == true

    def find_user
      by_uid = User.find_by(auth_uid: uid)
      return by_uid if by_uid
      return nil if email.nil?

      by_email = User.find_by("LOWER(email) = ?", email)
      return nil if by_email.nil?
      raise UnverifiedEmailConflict, "unverified email matches an existing account" unless email_verified?

      by_email
    end

    def update_existing(user)
      # email is deliberately absent: a sign-in must never rewrite the address
      # an account is known by.
      user.update!(
        auth_uid: uid,
        display_name: provider_data[:name].presence || user.display_name,
        photo_url: provider_data[:picture].presence || user.photo_url,
        external_provider: provider,
        email_verified: email_verified? || user.email_verified,
        last_sign_in_at: Time.current,
        sign_in_count: (user.sign_in_count || 0) + 1
      )
      persist_provider_data(user)
    end

    def build_new
      user = User.new(
        email: email,
        auth_uid: uid,
        display_name: provider_data[:name],
        photo_url: provider_data[:picture],
        external_provider: provider,
        email_verified: email_verified?,
        original_signup_domain: signup_domain,
        role: :user,
        last_sign_in_at: Time.current,
        sign_in_count: 1
      )
      persist_provider_data(user)
    end

    def persist_provider_data(user)
      user.provider_data ||= {}
      user.provider_data[provider.to_s] = provider_data
      user.save!
      user
    end
  end
end
