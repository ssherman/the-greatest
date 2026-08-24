require "test_helper"
require_relative "domain_policy_assertions"

module Books
  class AuthorPolicyTest < ActiveSupport::TestCase
    include Books::DomainPolicyAssertions

    setup do
      @author = books_authors(:tolstoy)
    end

    test "domain is books" do
      assert_equal "books", ::Books::AuthorPolicy.new(users(:admin_user), @author).domain
    end

    test "grants access by global role and books domain role" do
      assert_books_domain_policy(::Books::AuthorPolicy, @author)
    end

    test "a music-only user has no access" do
      refute ::Books::AuthorPolicy.new(music_user, @author).show?
    end

    test "execute_action is open to writers" do
      assert ::Books::AuthorPolicy.new(users(:editor_user), @author).execute_action?
      assert ::Books::AuthorPolicy.new(books_user(:editor), @author).execute_action?
      refute ::Books::AuthorPolicy.new(books_user(:viewer), @author).execute_action?
      refute ::Books::AuthorPolicy.new(music_user, @author).execute_action?
    end

    test "Scope resolves for books readers only" do
      assert_books_scope(::Books::AuthorPolicy, ::Books::Author)
    end
  end
end
