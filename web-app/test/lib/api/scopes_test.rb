require "test_helper"

module Api
  class ScopesTest < ActiveSupport::TestCase
    Account = Struct.new(:service?)

    test "the three read scopes are registered" do
      assert_equal ["books:read", "music:read", "games:read"], Scopes.all
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

    test "a person may mint only the member-mintable scopes" do
      assert_equal ["books:read", "music:read", "games:read"], Scopes.mintable_by(Account.new(false))
    end

    test "a service account may mint every registered scope" do
      assert_equal Scopes.all, Scopes.mintable_by(Account.new(true))
    end

    test "satisfies? is true when the exact scope is granted" do
      assert Scopes.satisfies?(["music:read", "books:read"], "books:read")
      refute Scopes.satisfies?(["music:read"], "books:read")
      refute Scopes.satisfies?([], "books:read")
    end

    test "satisfies? honours hierarchy: a scope covers what it implies" do
      write = Scopes::Scope.new(name: "books:write", description: "Write", member_mintable: false, implies: ["books:read"])
      Scopes.stubs(:registry).returns(Scopes::ALL.merge("books:write" => write))

      assert Scopes.satisfies?(["books:write"], "books:read")
      refute Scopes.satisfies?(["books:read"], "books:write")
    end

    test "satisfies? ignores unknown granted scopes rather than raising" do
      refute Scopes.satisfies?(["nope:read"], "books:read")
    end
  end
end
