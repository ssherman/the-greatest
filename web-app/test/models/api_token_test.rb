require "test_helper"

class ApiTokenTest < ActiveSupport::TestCase
  setup do
    @user = users(:regular_user)
  end

  test "generate returns the secret once and stores only its digest and prefix" do
    token, secret = ApiToken.generate(user: @user, name: "agent", scopes: ["books:read"])

    assert token.persisted?
    assert_match ApiToken::SECRET_FORMAT, secret
    assert_equal Digest::SHA256.hexdigest(secret), token.token_digest
    assert_equal secret[0, 12], token.token_prefix
    assert_nil token.expires_at
    refute ApiToken.column_names.include?("secret")
    refute token.attributes.value?(secret)
  end

  test "generate with an expiry" do
    freeze_time do
      token, _secret = ApiToken.generate(user: @user, name: "short", scopes: ["books:read"], expires_at: 30.days.from_now)

      assert_equal 30.days.from_now, token.expires_at
    end
  end

  test "authenticate finds a live token by its secret" do
    assert_equal api_tokens(:regular_user_token), ApiToken.authenticate(ApiTokenSecrets::MEMBER)
  end

  test "authenticate returns nil for an unknown secret" do
    assert_nil ApiToken.authenticate("tg_#{"z" * 40}")
  end

  test "authenticate returns nil for an expired token" do
    assert_nil ApiToken.authenticate(ApiTokenSecrets::EXPIRED)
  end

  test "authenticate rejects a malformed secret without querying" do
    queries = capture_sql do
      assert_nil ApiToken.authenticate(nil)
      assert_nil ApiToken.authenticate("")
      assert_nil ApiToken.authenticate("not-a-token")
      assert_nil ApiToken.authenticate("tg_short")
      assert_nil ApiToken.authenticate("tg_#{"m" * 40}!")
    end

    assert_equal 0, queries.size
  end

  test "expired? is false with no expiry, false before it, true at and after it" do
    token = api_tokens(:regular_user_token)
    refute token.expired?

    token.expires_at = 1.minute.from_now
    refute token.expired?

    token.expires_at = Time.current
    assert token.expired?
  end

  test "touch_last_used! writes once, then not again within five minutes" do
    token = api_tokens(:regular_user_token)
    assert_nil token.last_used_at

    freeze_time do
      token.touch_last_used!
      assert_equal Time.current, token.reload.last_used_at

      travel 4.minutes
      token.touch_last_used!
      assert_equal 4.minutes.ago, token.reload.last_used_at

      travel 2.minutes
      token.touch_last_used!
      assert_equal Time.current, token.reload.last_used_at
    end
  end

  test "requires a name of at most 60 characters" do
    token, _secret = ApiToken.generate(user: @user, name: "", scopes: ["books:read"])
    refute token.persisted?
    assert_includes token.errors[:name], "can't be blank"

    token, _secret = ApiToken.generate(user: @user, name: "x" * 61, scopes: ["books:read"])
    refute token.persisted?
    assert token.errors[:name].any?
  end

  test "requires at least one scope" do
    token, _secret = ApiToken.generate(user: @user, name: "empty", scopes: [])

    refute token.persisted?
    assert token.errors[:scopes].any?
  end

  test "rejects an unknown scope" do
    token, _secret = ApiToken.generate(user: @user, name: "bad", scopes: ["books:read", "films:read"])

    refute token.persisted?
    assert_includes token.errors[:scopes].join, "films:read"
  end

  test "rejects a scope the owner may not mint" do
    Api::Scopes.stubs(:mintable_by).with(@user).returns(["books:read"])

    token, _secret = ApiToken.generate(user: @user, name: "greedy", scopes: ["books:read", "music:read"])

    refute token.persisted?
    assert_includes token.errors[:scopes].join, "music:read"
  end

  test "an account holds at most the configured number of tokens" do
    cap = Rails.application.config.x.api.max_tokens_per_user
    existing = @user.api_tokens.count
    (cap - existing).times do |n|
      token, _secret = ApiToken.generate(user: @user, name: "fill-#{n}", scopes: ["books:read"])
      assert token.persisted?, token.errors.full_messages.join(", ")
    end

    token, _secret = ApiToken.generate(user: @user, name: "one-too-many", scopes: ["books:read"])

    refute token.persisted?
    assert token.errors[:base].any?
  end

  test "destroying a user destroys their tokens" do
    user = User.create!(email: "temp-token-owner@example.com", role: :user, email_verified: false, display_name: "Temp")
    ApiToken.generate(user: user, name: "t", scopes: ["books:read"])

    assert_difference("ApiToken.count", -1) { user.destroy! }
  end

  private

  def capture_sql
    queries = []
    callback = ->(_n, _s, _f, _i, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    queries
  end
end
