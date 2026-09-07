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

    # Providers that require email ownership at signup, so their address
    # assertion is trusted for account linking even when Firebase passes no
    # email_verified flag. X in particular verifies by confirmation mail but
    # exposes no flag for it, and Firebase therefore sends false.
    #
    # The question this answers is NOT "did the token say verified" -- it is
    # "could someone have registered this address at this provider without
    # controlling it". Google requires proving control of an address before
    # an account can use it, and X requires confirming an address before it
    # activates an account that uses it.
    #
    # That is weaker than it sounds, though: the token's `email` claim is the
    # Firebase account RECORD's email, not necessarily the address the
    # provider asserted at signup, and Firebase lets an account holder change
    # their own Firebase-record email afterward. So this list trusts the
    # provider's identity -- that Google, Apple, X, or Facebook vouches this
    # is a real, controlled account -- not the provenance of whatever address
    # happens to be on today's token.
    #
    # "password" is deliberately absent and MUST stay absent: a Firebase
    # password account can be created for any address without proving control,
    # which is precisely the account-takeover route UnverifiedEmailConflict
    # exists to block.
    #
    # This list is enumerated, never derived. A future provider that does not
    # require email ownership must not become trusted merely by not being
    # "password". It is also deliberately NOT read from
    # config/auth_providers.json: enabling a button must never widen a security
    # decision as a side effect.
    TRUSTED_EMAIL_PROVIDERS = %w[google.com apple.com facebook.com twitter.com].freeze

    def self.call(auth_token:, project_id:, signup_domain: nil)
      payload = JwtValidationService.call(auth_token, project_id: project_id)
      provider_data = extract_provider_data(payload)

      user = UserAuthenticationService.call(
        provider_data: provider_data,
        signup_domain: signup_domain,
        email_resolver: ProviderEmailResolver.new(
          uid: payload["sub"],
          sign_in_provider: payload.dig("firebase", "sign_in_provider"),
          project_id: project_id,
          fallback_email: payload["email"]
        )
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
    rescue FirebaseAccountLookup::Error, GoogleServiceAccountToken::Error => e
      # Refuse rather than guess. Without the address we cannot tell a new user
      # from an existing one adding a provider, and proceeding would silently
      # create a duplicate of a real account -- permanent, and undoable only by
      # a merge. A refused sign-in is temporary and self-heals on retry.
      #
      # This clause MUST stay above the catch-all `rescue => e` below; Ruby
      # matches rescue clauses in order, and the catch-all would otherwise
      # flatten this into a generic :authentication_failed.
      Rails.logger.error "Firebase account lookup failed: #{e.class}: #{e.message}"
      {
        success: false,
        error: "We couldn't complete sign-in. Please try again.",
        error_code: :account_lookup_failed
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
        # The provider's OWN user id (X's numeric id, Facebook's app-scoped
        # id) -- not the Firebase uid above. It is the only reconnection key
        # for an email-less OAuth user, because provider ids (X's especially,
        # see F5) are stable across apps and Firebase uids are not portable
        # at all. Lives under the firebase claim's identities map, keyed by
        # sign_in_provider, as an array; take the first element. Deliberately
        # does NOT fall back to `sub` -- that is the Firebase uid, and writing
        # it here would poison the column with values that match nothing.
        provider_uid: Array(payload.dig("firebase", "identities", sign_in_provider)).first,
        email: payload["email"],
        name: payload["name"],
        picture: payload["picture"],
        # Strict true: Firebase sends a real boolean, and `|| false` on a
        # missing claim must not become "verified".
        email_verified: payload["email_verified"] == true,
        # What the linking decision actually uses. Kept separate from the raw
        # claim above so the users.email_verified column keeps recording what
        # the provider genuinely asserted.
        email_trusted: payload["email_verified"] == true ||
          TRUSTED_EMAIL_PROVIDERS.include?(sign_in_provider),
        provider: provider,
        auth_time: payload["auth_time"],
        iat: payload["iat"],
        exp: payload["exp"]
      }
    end

    private_class_method :extract_provider_data
  end
end
