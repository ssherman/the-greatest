require "test_helper"

module Api
  class ScopesTest < ActiveSupport::TestCase
    test "eligible_for asks the membership question once" do
      user = users(:regular_user)
      queries = capture_sql { Scopes.eligible_for(user) }.grep(/memberships/)

      assert_equal 1, queries.size
    end

    test "registers the admin scopes" do
      assert_equal ["books:read", "music:read", "games:read", "books:admin:read", "books:admin:merge"], Scopes.all
      assert Scopes.admin?("books:admin:merge")
      refute Scopes.admin?("books:read")
    end

    test "known? and description" do
      assert Scopes.known?("books:read")
      assert Scopes.known?(:books_read.to_s.tr("_", ":"))
      refute Scopes.known?("books:write")
      assert_match(/books/i, Scopes.description("books:read"))
    end

    test "description of an unknown scope raises" do
      assert_raises(Scopes::UnknownScope) { Scopes.description("nope:read") }
    end

    test "a member is eligible for the read scopes only" do
      assert_equal ["books:read", "music:read", "games:read"], Scopes.eligible_for(users(:regular_user)).sort_by { Scopes.all.index(it) }
    end

    test "a non-member with no role is eligible for nothing" do
      assert_empty Scopes.eligible_for(users(:user_with_expired_membership))
    end

    test "a global admin without a membership is eligible for every books scope, but not other sites' reads" do
      admin = users(:admin_user)
      admin.memberships.destroy_all
      assert_equal ["books:read", "books:admin:read", "books:admin:merge"].sort, Scopes.eligible_for(admin).sort
    end

    test "a global editor is eligible for merge" do
      assert_includes Scopes.eligible_for(users(:editor_user)), "books:admin:merge"
    end

    test "a books domain admin is eligible for merge" do
      user = users(:user_with_expired_membership)
      DomainRole.create!(user: user, domain: :books, permission_level: :admin)
      assert_includes Scopes.eligible_for(user), "books:admin:merge"
    end

    test "a books viewer may read admin data but not merge" do
      eligible = Scopes.eligible_for(users(:books_viewer_user))
      assert_includes eligible, "books:admin:read"
      assert_includes eligible, "books:read"
      refute_includes eligible, "books:admin:merge"
    end

    test "a games-only editor gains no books admin scope" do
      refute_includes Scopes.eligible_for(users(:games_editor_user)), "books:admin:read"
    end

    test "a service account gets the read scopes and no admin scope" do
      assert_equal ["books:read", "music:read", "games:read"], Scopes.eligible_for(users(:agent_runner_service_account))
    end

    test "mintable_by is eligible_for" do
      user = users(:books_viewer_user)
      assert_equal Scopes.eligible_for(user), Scopes.mintable_by(user)
    end

    test "effective expands implied scopes before intersecting" do
      viewer = users(:books_viewer_user)
      assert_equal ["books:read", "books:admin:read"].sort, Scopes.effective(["books:admin:merge"], viewer).sort
    end

    test "effective drops scopes the user no longer qualifies for and unknown scopes" do
      assert_equal ["books:read"], Scopes.effective(["books:read", "books:admin:merge", "retired:scope"], users(:regular_user))
    end

    test "satisfies? is true when the exact scope is granted" do
      assert Scopes.satisfies?(["music:read", "books:read"], "books:read")
      refute Scopes.satisfies?(["music:read"], "books:read")
      refute Scopes.satisfies?([], "books:read")
    end

    test "satisfies? honours hierarchy: a scope covers what it implies" do
      write = Scopes::Scope.new(name: "books:write", description: "Write", admin: false, implies: ["books:read"], eligible: ->(_) { true })
      Scopes.stubs(:registry).returns(Scopes::ALL.merge("books:write" => write))

      assert Scopes.satisfies?(["books:write"], "books:read")
      refute Scopes.satisfies?(["books:read"], "books:write")
    end

    test "satisfies? ignores unknown granted scopes rather than raising" do
      refute Scopes.satisfies?(["nope:read"], "books:read")
    end
  end
end
