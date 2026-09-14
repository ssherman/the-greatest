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

# A personal access token for the public API: the persistence layer only.
# Minting, resolving a presented secret and recording use live in
# Services::Api::Tokens -- the secret never touches this class. Rate limits key
# on the owning USER, not the token (Services::Api::RateLimiter), so the
# per-account cap here is about hygiene, not quota.
class ApiToken < ApplicationRecord
  belongs_to :user

  validates :name, presence: true, length: {maximum: 60}
  validates :token_digest, presence: true, uniqueness: true
  validates :token_prefix, presence: true
  validates :scopes, presence: true
  validate :scopes_are_known_and_mintable
  validate :owner_is_under_the_cap, on: :create

  def expired? = expires_at.present? && expires_at <= Time.current

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
