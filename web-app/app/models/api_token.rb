# == Schema Information
#
# Table name: api_tokens
#
#  id           :bigint           not null, primary key
#  expires_at   :datetime
#  last_used_at :datetime
#  name         :string           not null
#  scopes       :string           default([]), not null, is an Array
#  token_digest :string           not null
#  token_prefix :string           not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  user_id      :bigint           not null
#
# Indexes
#
#  index_api_tokens_on_token_digest  (token_digest) UNIQUE
#  index_api_tokens_on_user_id       (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
# frozen_string_literal: true

# A personal access token for the public API.
#
# Only the SHA-256 digest of the secret is stored. The secret exists in exactly
# one place -- the second element of .generate's return value -- and is gone
# once the caller drops it. This is the scheme GitHub, GitLab and Discourse use,
# and it does not depend on the scheme being private: an attacker with the
# source and a copy of the table needs a SHA-256 preimage of a 238-bit random
# string. bcrypt is deliberately NOT used: it exists to slow brute force on
# low-entropy secrets and would add ~100 ms to every API request for nothing.
#
# Rate limits key on the owning USER, not the token (Services::Api::RateLimiter),
# so the per-account cap here is about hygiene, not quota.
class ApiToken < ApplicationRecord
  PREFIX = "tg_"
  SECRET_LENGTH = 40
  SECRET_FORMAT = /\A#{PREFIX}[A-Za-z0-9]{#{SECRET_LENGTH}}\z/
  PREFIX_DISPLAY_LENGTH = 12
  LAST_USED_WRITE_INTERVAL = 5.minutes

  belongs_to :user

  validates :name, presence: true, length: {maximum: 60}
  validates :token_digest, presence: true, uniqueness: true
  validates :token_prefix, presence: true
  validates :scopes, presence: true
  validate :scopes_are_known_and_mintable
  validate :owner_is_under_the_cap, on: :create

  # Returns [record, secret]. The record is unpersisted (with errors) when
  # validation fails; the secret is still returned so the caller's control flow
  # stays uniform, and it is worthless without the row.
  def self.generate(user:, name:, scopes:, expires_at: nil)
    secret = PREFIX + SecureRandom.alphanumeric(SECRET_LENGTH)
    record = new(
      user: user,
      name: name,
      scopes: scopes,
      expires_at: expires_at,
      token_digest: digest(secret),
      token_prefix: secret[0, PREFIX_DISPLAY_LENGTH]
    )
    record.save
    [record, secret]
  end

  # The live token for a secret, or nil. A malformed secret never reaches the
  # database. secure_compare on the found digest is belt-and-braces: an indexed
  # lookup on a 256-bit digest is not a practical timing oracle, but the compare
  # costs nothing.
  def self.authenticate(secret)
    return nil unless SECRET_FORMAT.match?(secret.to_s)

    candidate = digest(secret)
    token = find_by(token_digest: candidate)
    return nil unless token && ActiveSupport::SecurityUtils.secure_compare(token.token_digest, candidate)
    return nil if token.expired?

    token
  end

  def self.digest(secret) = Digest::SHA256.hexdigest(secret)

  def expired? = expires_at.present? && expires_at <= Time.current

  # At most one write per LAST_USED_WRITE_INTERVAL, so a busy agent does not
  # cost an UPDATE per request. update_column: no validations, no callbacks,
  # no updated_at churn.
  def touch_last_used!
    return if last_used_at.present? && last_used_at > LAST_USED_WRITE_INTERVAL.ago

    update_column(:last_used_at, Time.current)
  end

  private

  def scopes_are_known_and_mintable
    return if scopes.blank? || user.nil?

    unknown = scopes.reject { |scope| Api::Scopes.known?(scope) }
    errors.add(:scopes, "unknown: #{unknown.join(", ")}") if unknown.any?

    forbidden = (scopes - unknown) - Api::Scopes.mintable_by(user)
    errors.add(:scopes, "not available to this account: #{forbidden.join(", ")}") if forbidden.any?
  end

  def owner_is_under_the_cap
    return if user.nil?

    cap = Rails.application.config.x.api.max_tokens_per_user
    errors.add(:base, "You can have at most #{cap} tokens") if user.api_tokens.count >= cap
  end
end
