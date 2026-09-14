# frozen_string_literal: true

module Services
  module Api
    # The token lifecycle: minting a secret, resolving a presented secret to a
    # live ApiToken, and recording use. ApiToken itself is the persistence layer
    # (validations, associations, the expired? predicate); this is the security
    # boundary.
    #
    # Only the SHA-256 digest of a secret is ever stored. The secret exists in
    # exactly one place -- `generate`'s Result -- and is gone once the caller
    # drops it. This is the scheme GitHub, GitLab and Discourse use, and it does
    # not depend on the scheme being private: an attacker with the source and a
    # copy of the table needs a SHA-256 preimage of a 238-bit random string.
    # bcrypt is deliberately NOT used: it exists to slow brute force on
    # low-entropy secrets and would add ~100 ms to every API request for nothing.
    class Tokens
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      PREFIX = "tg_"
      SECRET_LENGTH = 40
      SECRET_FORMAT = /\A#{PREFIX}[A-Za-z0-9]{#{SECRET_LENGTH}}\z/
      PREFIX_DISPLAY_LENGTH = 12
      LAST_USED_WRITE_INTERVAL = 5.minutes

      # Mints a token. data is {token:, secret:} on success; on validation
      # failure the errors are the record's full messages and nothing is stored.
      def self.generate(user:, name:, scopes:, expires_at: nil)
        secret = PREFIX + SecureRandom.alphanumeric(SECRET_LENGTH)
        token = ApiToken.new(
          user: user,
          name: name,
          scopes: scopes,
          expires_at: expires_at,
          token_digest: digest(secret),
          token_prefix: secret[0, PREFIX_DISPLAY_LENGTH]
        )
        return failure(*token.errors.full_messages) unless token.save

        success(token: token, secret: secret)
      end

      # The live token for a presented secret, or nil. A malformed secret never
      # reaches the database. secure_compare on the found digest is
      # belt-and-braces: an indexed lookup on a 256-bit digest is not a practical
      # timing oracle, but the compare costs nothing.
      def self.authenticate(secret)
        return nil unless SECRET_FORMAT.match?(secret.to_s)

        candidate = digest(secret)
        token = ApiToken.find_by(token_digest: candidate)
        return nil unless token && ActiveSupport::SecurityUtils.secure_compare(token.token_digest, candidate)
        return nil if token.expired?

        token
      end

      # At most one write per LAST_USED_WRITE_INTERVAL, so a busy agent does not
      # cost an UPDATE per request. update_column: no validations, no callbacks,
      # no updated_at churn.
      def self.record_use(token)
        return if token.last_used_at.present? && token.last_used_at > LAST_USED_WRITE_INTERVAL.ago

        token.update_column(:last_used_at, Time.current)
      end

      def self.digest(secret) = Digest::SHA256.hexdigest(secret)

      def self.success(data) = Result.new(success?: true, data: data, errors: [])

      def self.failure(*messages) = Result.new(success?: false, data: nil, errors: messages)
    end
  end
end
