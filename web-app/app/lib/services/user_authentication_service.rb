# Finds or creates the User a verified Firebase token belongs to.
#
# The lookup order is the security boundary:
#
#   1. auth_uid == the token's `sub`. Exact, and it came out of a signature.
#   2. a VERIFIED email. Control of an address proves ownership of the account
#      that uses it, so this relinks -- a V1 user imported under one uid who
#      later signs in with Google presents a different sub, and refusing would
#      lock them out of their own data.
#   3. an UNTRUSTED email that matches an existing account is refused outright.
#      This is the takeover route: anyone can create a Firebase password account
#      for someone else's address, and the previous version matched on email
#      unconditionally and then update!'d that row.
#
#      "Trusted" is broader than "verified" on purpose. A real OAuth provider
#      already proved ownership at signup, and X does so without ever sending
#      an email_verified flag -- so gating on the flag alone would send every
#      returning X user to a verification wall. See
#      AuthenticationService::TRUSTED_EMAIL_PROVIDERS. password is not on that
#      list and never will be.
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
    def provider_uid = provider_data[:provider_uid]
    def email = provider_data[:email].presence&.downcase
    def email_verified? = provider_data[:email_verified] == true
    def email_trusted? = provider_data[:email_trusted] == true

    def find_user
      by_uid = User.find_by(auth_uid: uid)
      return by_uid if by_uid
      return nil if email.nil?

      # .order(:id).first, not find_by: the database currently holds
      # case-insensitively duplicate email rows, and this lookup sits on the
      # security boundary (see the class comment). Without an explicit order,
      # which row wins is Postgres's choice and can change between query plans.
      by_email = User.where("LOWER(email) = ?", email).order(:id).first
      return nil if by_email.nil?
      raise UnverifiedEmailConflict, "untrusted email matches an existing account" unless email_trusted?

      by_email
    end

    def update_existing(user)
      # Fill a blank, never overwrite -- for both email and
      # external_provider_uid. Rewriting the address an account is known by
      # would be an account-takeover primitive; filling a blank is not, and
      # it is the only way an email-less OAuth row (X supplies no address for
      # roughly 4% of sign-ins, and 20,063 legacy rows have none) ever
      # becomes linkable to the same human's other providers.
      # external_provider_uid gets the identical treatment for the identical
      # reason: a row may already hold a legacy provider id (X's especially,
      # since it is the only globally stable one -- see F5), and a later
      # sign-in with a different provider must not clobber it with THAT
      # provider's id.
      #
      # The email fill is also gated on email_trusted?, not just on the row being
      # uid-matched. Without that gate, an attacker holding an email-less
      # OAuth row could link a password credential to the same Firebase user
      # with any unclaimed address and have this fill write it onto their row
      # on the next sign-in -- and that address then becomes what a LATER
      # trusted sign-in matches on in find_user. Every legitimate case in the
      # design (X, Google, Apple, Facebook, and a verified password sign-in)
      # is trusted, so this gate changes no real behaviour.
      #
      # The fill is skippable, though: this uid-matched row can be blank
      # while the token's address already belongs to a different row (the
      # class comment above notes the table holds case-insensitive
      # duplicates), and writing it here would hit :email's uniqueness
      # validation and fail the whole sign-in. The person already
      # authenticated and matched by uid -- failing that to protect an
      # optional convenience would invert the priority, so a collision just
      # leaves the row exactly as blank as it already was.
      user.update!(
        email: user.email.presence || (email_trusted? ? fillable_email(user) : nil),
        auth_uid: uid,
        external_provider_uid: user.external_provider_uid.presence || provider_uid,
        display_name: provider_data[:name].presence || user.display_name,
        photo_url: provider_data[:picture].presence || user.photo_url,
        external_provider: provider,
        email_verified: email_verified? || user.email_verified,
        last_sign_in_at: Time.current,
        sign_in_count: (user.sign_in_count || 0) + 1
      )
      persist_provider_data(user)
    end

    # The token's email, unless a different row already has it. Case-
    # insensitive, matching find_user's own lookup style. Self-excluding so
    # this reads correctly standing alone -- the only caller already
    # guarantees user.email is blank, so self-exclusion can't change the
    # result today, but the method shouldn't depend on that to be correct.
    def fillable_email(user)
      return nil if email.nil?
      return nil if User.where("LOWER(email) = ?", email).where.not(id: user.id).exists?

      email
    end

    def build_new
      user = User.new(
        email: email,
        auth_uid: uid,
        external_provider_uid: provider_uid,
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
