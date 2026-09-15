require "test_helper"

# Persistence-layer tests only. Minting, resolving a secret and recording use
# are Services::Api::Tokens (test/lib/services/api/tokens_test.rb).
class ApiTokenTest < ActiveSupport::TestCase
  setup do
    @user = users(:regular_user)
  end

  def build(**overrides)
    ApiToken.new({user: @user, name: "agent", scopes: ["books:read"],
                  token_digest: Digest::SHA256.hexdigest("tg_#{SecureRandom.alphanumeric(40)}"),
                  token_prefix: "tg_123456789"}.merge(overrides))
  end

  test "a well-formed token is valid" do
    assert build.valid?
  end

  test "expired? is false with no expiry, false before it, true at and after it" do
    token = api_tokens(:regular_user_token)
    refute token.expired?

    token.expires_at = 1.minute.from_now
    refute token.expired?

    token.expires_at = Time.current
    assert token.expired?
  end

  test "requires a name of at most 60 characters" do
    token = build(name: "")
    refute token.valid?
    assert_includes token.errors[:name], "can't be blank"

    token = build(name: "x" * 61)
    refute token.valid?
    assert token.errors[:name].any?
  end

  test "requires a digest and a prefix" do
    refute build(token_digest: nil).valid?
    refute build(token_prefix: nil).valid?
  end

  test "the digest is unique" do
    token = build(token_digest: api_tokens(:regular_user_token).token_digest)

    refute token.valid?
    assert token.errors[:token_digest].any?
  end

  test "requires at least one scope" do
    token = build(scopes: [])

    refute token.valid?
    assert token.errors[:scopes].any?
  end

  test "rejects an unknown scope" do
    token = build(scopes: ["books:read", "films:read"])

    refute token.valid?
    assert_includes token.errors[:scopes].join, "films:read"
  end

  test "rejects a scope the owner may not mint" do
    Api::Scopes.stubs(:mintable_by).with(@user).returns(["books:read"])

    token = build(scopes: ["books:read", "music:read"])

    refute token.valid?
    assert_includes token.errors[:scopes].join, "music:read"
  end

  test "an account holds at most the configured number of tokens" do
    cap = Rails.application.config.x.api.max_tokens_per_user
    existing = @user.api_tokens.count
    (cap - existing).times do |n|
      assert build(name: "fill-#{n}").save, "token #{n} should save"
    end

    token = build(name: "one-too-many")

    refute token.save
    assert token.errors[:base].any?
  end

  test "destroying a user destroys their tokens" do
    user = User.create!(email: "temp-token-owner@example.com", role: :user, email_verified: false, display_name: "Temp")
    ApiToken.create!(user: user, name: "t", scopes: ["books:read"],
      token_digest: Digest::SHA256.hexdigest("tg_#{SecureRandom.alphanumeric(40)}"), token_prefix: "tg_abcdefghi")

    assert_difference("ApiToken.count", -1) { user.destroy! }
  end
end
