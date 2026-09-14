require "test_helper"

module Services
  module Api
    class ServiceAccountsTest < ActiveSupport::TestCase
      test "create makes a service account and mints one token" do
        result = nil
        assert_difference ["User.count", "ApiToken.count"], 1 do
          result = ServiceAccounts.create(name: "nightly-sync", scopes: ["books:read", "music:read"])
        end

        assert result.success?, result.errors.join(", ")
        user = result.data[:user]
        assert user.service?
        assert_equal "nightly-sync@service-accounts.thegreatest.invalid", user.email
        assert_equal "nightly-sync", user.display_name
        assert_equal 0, user.user_lists.count
        token = result.data[:token]
        assert_equal "default", token.name
        assert_equal ["books:read", "music:read"], token.scopes
        assert_match ApiToken::SECRET_FORMAT, result.data[:secret]
        assert_equal token, ApiToken.authenticate(result.data[:secret])
      end

      test "create is find-or-create on the account and always mints a new token" do
        ServiceAccounts.create(name: "nightly-sync", scopes: ["books:read"])

        assert_no_difference "User.count" do
          assert_difference "ApiToken.count", 1 do
            result = ServiceAccounts.create(name: "nightly-sync", scopes: ["books:read"], token_name: "second")
            assert result.success?
            assert_equal "second", result.data[:token].name
          end
        end
      end

      test "create rejects a name that is not lowercase-kebab" do
        result = ServiceAccounts.create(name: "Nightly Sync", scopes: ["books:read"])

        refute result.success?
        assert_match(/NAME/, result.errors.first)
      end

      test "create rejects an unknown scope without creating the account" do
        assert_no_difference "User.count" do
          result = ServiceAccounts.create(name: "bad-scope", scopes: ["films:read"])
          refute result.success?
          assert_match(/films:read/, result.errors.join)
        end
      end

      test "mint adds a token to an existing service account" do
        user = users(:agent_runner_service_account)

        result = ServiceAccounts.mint(name: "agent-runner", token_name: "prod-2", scopes: ["games:read"])

        assert result.success?
        assert_equal user, result.data[:token].user
        assert_equal ["games:read"], result.data[:token].scopes
      end

      test "mint fails for an unknown account" do
        result = ServiceAccounts.mint(name: "nobody", token_name: "x", scopes: ["books:read"])

        refute result.success?
        assert_match(/no service account/i, result.errors.first)
      end

      test "revoke destroys a token by id" do
        token = api_tokens(:service_account_token)

        assert_difference "ApiToken.count", -1 do
          assert ServiceAccounts.revoke(id: token.id).success?
        end
        assert_nil ApiToken.authenticate(ApiTokenSecrets::SERVICE)
      end

      test "revoke of an unknown id fails" do
        refute ServiceAccounts.revoke(id: 0).success?
      end
    end
  end
end
