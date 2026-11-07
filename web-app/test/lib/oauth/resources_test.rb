require "test_helper"

module Oauth
  class ResourcesTest < ActiveSupport::TestCase
    test "mcp is the one registered resource" do
      assert_equal ["mcp"], Resources.keys
      mcp = Resources.fetch("mcp")
      assert_equal "/api/mcp", mcp.path
      assert_not mcp.admin
    end

    test "a resource knows its scopes, url and metadata path" do
      mcp = Resources.fetch("mcp")

      assert_equal ["books:read"], mcp.scopes(:books)
      assert_equal ["music:read"], mcp.scopes("music")
      assert_equal "https://books.example/api/mcp", mcp.url("https://books.example")
      assert_equal "/.well-known/oauth-protected-resource/api/mcp", mcp.metadata_path
    end

    test "fetch raises for an unknown key" do
      assert_raises(KeyError) { Resources.fetch("rest") }
    end

    test "for_path matches the exact path only" do
      assert_equal "mcp", Resources.for_path("/api/mcp").key
      assert_nil Resources.for_path("/api/mcp/admin")
      assert_nil Resources.for_path("/api/mcp/")
      assert_nil Resources.for_path("/api/v1/books")
    end

    test "for_url matches the resource's full url exactly" do
      assert_equal "mcp", Resources.for_url("https://books.example/api/mcp", "https://books.example").key
      assert_nil Resources.for_url("https://books.example/api/mcp/admin", "https://books.example")
      assert_nil Resources.for_url("https://other.example/api/mcp", "https://books.example")
      assert_nil Resources.for_url(nil, "https://books.example")
    end

    test "infer is mcp for read scopes, admin scopes and unknown scopes while no admin resource exists" do
      assert_equal "mcp", Resources.infer(["books:read"]).key
      assert_equal "mcp", Resources.infer(["books:admin:merge"]).key
      assert_equal "mcp", Resources.infer(["offline_access"]).key
      assert_equal "mcp", Resources.infer([]).key
    end

    test "all_scopes lists every registered resource's scopes for the domain" do
      assert_equal ["books:read"], Resources.all_scopes(:books)
    end

    test "a member is granted the read scope when none is requested" do
      mcp = Resources.fetch("mcp")

      assert_equal ["books:read"], Resources.grantable_scopes(users(:regular_user), mcp, :books, requested: nil)
    end

    test "offline_access and scopes outside the resource are dropped" do
      mcp = Resources.fetch("mcp")

      assert_equal ["books:read"],
        Resources.grantable_scopes(users(:regular_user), mcp, :books, requested: ["books:read", "offline_access"])
      assert_equal [],
        Resources.grantable_scopes(users(:regular_user), mcp, :books, requested: ["books:admin:merge"])
    end

    test "a request for offline_access alone is treated as asking for nothing" do
      mcp = Resources.fetch("mcp")

      assert_equal ["books:read"],
        Resources.grantable_scopes(users(:regular_user), mcp, :books, requested: ["offline_access"])
      assert_equal [],
        Resources.grantable_scopes(users(:user_with_expired_membership), mcp, :books, requested: ["offline_access"])
    end

    test "a user with no membership and no role is granted nothing" do
      mcp = Resources.fetch("mcp")
      user = users(:regular_user)
      user.memberships.update_all(status: :unpaid)

      assert_equal [], Resources.grantable_scopes(user, mcp, :books, requested: nil)
    end

    test "a books admin who is not a member is granted the read scope through implies" do
      mcp = Resources.fetch("mcp")
      admin = users(:admin_user)
      admin.memberships.destroy_all

      assert_equal ["books:read"], Resources.grantable_scopes(admin, mcp, :books, requested: nil)
    end
  end
end
