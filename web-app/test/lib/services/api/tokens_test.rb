require "test_helper"

module Services
  module Api
    class TokensTest < ActiveSupport::TestCase
      setup do
        @user = users(:regular_user)
      end

      test "generate returns the secret once and stores only its digest and prefix" do
        result = Tokens.generate(user: @user, name: "agent", scopes: ["books:read"])

        assert result.success?, result.errors.join(", ")
        token = result.data[:token]
        secret = result.data[:secret]
        assert token.persisted?
        assert_match Tokens::SECRET_FORMAT, secret
        assert_equal Digest::SHA256.hexdigest(secret), token.token_digest
        assert_equal secret[0, 12], token.token_prefix
        assert_nil token.expires_at
        refute ApiToken.column_names.include?("secret")
        refute token.attributes.value?(secret)
      end

      test "generate with an expiry" do
        freeze_time do
          result = Tokens.generate(user: @user, name: "short", scopes: ["books:read"], expires_at: 30.days.from_now)

          assert_equal 30.days.from_now, result.data[:token].expires_at
        end
      end

      test "generate fails with the record's messages and stores nothing" do
        assert_no_difference "ApiToken.count" do
          result = Tokens.generate(user: @user, name: "", scopes: ["books:read", "films:read"])

          refute result.success?
          assert_nil result.data
          assert(result.errors.any? { |message| message.include?("Name") })
          assert(result.errors.any? { |message| message.include?("films:read") })
        end
      end

      test "authenticate finds a live token by its secret" do
        assert_equal api_tokens(:regular_user_token), Tokens.authenticate(ApiTokenSecrets::MEMBER)
      end

      test "authenticate returns nil for an unknown secret" do
        assert_nil Tokens.authenticate("tg_#{"z" * 40}")
      end

      test "authenticate returns nil for an expired token" do
        assert_nil Tokens.authenticate(ApiTokenSecrets::EXPIRED)
      end

      test "authenticate rejects a malformed secret without querying" do
        assert_no_queries do
          assert_nil Tokens.authenticate(nil)
          assert_nil Tokens.authenticate("")
          assert_nil Tokens.authenticate("not-a-token")
          assert_nil Tokens.authenticate("tg_short")
          assert_nil Tokens.authenticate("tg_#{"m" * 40}!")
        end
      end

      test "record_use writes once, then not again within five minutes" do
        token = api_tokens(:regular_user_token)
        assert_nil token.last_used_at

        freeze_time do
          Tokens.record_use(token)
          assert_equal Time.current, token.reload.last_used_at

          travel 4.minutes
          Tokens.record_use(token)
          assert_equal 4.minutes.ago, token.reload.last_used_at

          travel 2.minutes
          Tokens.record_use(token)
          assert_equal Time.current, token.reload.last_used_at
        end
      end
    end
  end
end
