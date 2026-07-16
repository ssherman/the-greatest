require "test_helper"
require_relative "domain_policy_assertions"

module Books
  class EditionPolicyTest < ActiveSupport::TestCase
    include Books::DomainPolicyAssertions

    setup do
      @edition = books_editions(:wp_maude)
    end

    test "domain is books" do
      assert_equal "books", ::Books::EditionPolicy.new(users(:admin_user), @edition).domain
    end

    test "grants access by global role and books domain role" do
      assert_books_domain_policy(::Books::EditionPolicy, @edition)
    end

    test "a music-only user has no access" do
      refute ::Books::EditionPolicy.new(music_user, @edition).show?
    end

    test "set_default? mirrors update?" do
      assert ::Books::EditionPolicy.new(users(:admin_user), @edition).set_default?
      refute ::Books::EditionPolicy.new(users(:regular_user), @edition).set_default?
    end

    test "Scope resolves for books readers only" do
      assert_books_scope(::Books::EditionPolicy, ::Books::Edition)
    end
  end
end
