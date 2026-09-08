# frozen_string_literal: true

module Services
  # Resolves the address an account-linking decision should use.
  #
  # Prefers the identity provider's own assertion over the token's `email`
  # claim, and that ordering is the security property, not an optimisation.
  # The claim is the Firebase ACCOUNT RECORD's email, which its holder can
  # repoint via Identity Toolkit accounts:update while sign_in_provider stays
  # put -- the account-takeover route found in PR #300's final review. The
  # provider record holds what the provider vouched for and is not writable by
  # the account holder.
  #
  # Errors propagate on purpose. See the failure test in
  # test/lib/services/provider_email_resolver_test.rb.
  class ProviderEmailResolver
    def initialize(uid:, sign_in_provider:, project_id:, fallback_email: nil)
      @uid = uid
      @sign_in_provider = sign_in_provider
      @project_id = project_id
      @fallback_email = fallback_email
    end

    def call
      entry = provider_entry
      provider_email = entry && entry["email"].presence

      provider_email || @fallback_email.presence
    end

    private

    def provider_entry
      entries = FirebaseAccountLookup.call(@uid, project_id: @project_id)
      entries.find { |e| e["providerId"] == @sign_in_provider }
    end
  end
end
