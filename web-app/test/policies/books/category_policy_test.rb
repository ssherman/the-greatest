require "test_helper"
require_relative "domain_policy_assertions"

module Books
  class CategoryPolicyTest < ActiveSupport::TestCase
    include Books::DomainPolicyAssertions

    setup do
      @category = categories(:books_fiction_genre)
    end

    test "domain is books" do
      assert_equal "books", ::Books::CategoryPolicy.new(users(:admin_user), @category).domain
    end

    test "grants access by global role and books domain role" do
      assert_books_domain_policy(::Books::CategoryPolicy, @category)
    end

    test "a music-only user has no access" do
      refute ::Books::CategoryPolicy.new(music_user, @category).show?
    end

    test "Scope resolves for books readers only" do
      assert_books_scope(::Books::CategoryPolicy, ::Books::Category)
    end
  end
end
