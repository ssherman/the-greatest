require "test_helper"
require_relative "domain_policy_assertions"

module Books
  class ListPolicyTest < ActiveSupport::TestCase
    include Books::DomainPolicyAssertions

    setup do
      @list = lists(:basic_list)
    end

    test "the fixture is a books list" do
      assert_instance_of ::Books::List, @list
    end

    test "domain is books" do
      assert_equal "books", ::Books::ListPolicy.new(users(:admin_user), @list).domain
    end

    test "grants access by global role and books domain role" do
      assert_books_domain_policy(::Books::ListPolicy, @list)
    end

    test "a music-only user has no access" do
      refute ::Books::ListPolicy.new(music_user, @list).show?
    end

    test "Scope resolves for books readers only" do
      assert_books_scope(::Books::ListPolicy, ::Books::List)
    end
  end
end
