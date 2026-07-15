require "test_helper"
require_relative "domain_policy_assertions"

module Books
  class BookPolicyTest < ActiveSupport::TestCase
    include Books::DomainPolicyAssertions

    setup do
      @book = books_books(:war_and_peace)
    end

    test "domain is books" do
      assert_equal "books", ::Books::BookPolicy.new(users(:admin_user), @book).domain
    end

    test "grants access by global role and books domain role" do
      assert_books_domain_policy(::Books::BookPolicy, @book)
    end

    test "a music-only user has no access" do
      refute ::Books::BookPolicy.new(music_user, @book).show?
      refute ::Books::BookPolicy.new(music_user, @book).update?
    end

    test "Scope resolves for books readers only" do
      assert_books_scope(::Books::BookPolicy, ::Books::Book)
    end
  end
end
