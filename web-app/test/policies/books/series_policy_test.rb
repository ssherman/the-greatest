require "test_helper"
require_relative "domain_policy_assertions"

module Books
  class SeriesPolicyTest < ActiveSupport::TestCase
    include Books::DomainPolicyAssertions

    setup do
      @series = books_series(:asoiaf)
    end

    test "domain is books" do
      assert_equal "books", ::Books::SeriesPolicy.new(users(:admin_user), @series).domain
    end

    test "grants access by global role and books domain role" do
      assert_books_domain_policy(::Books::SeriesPolicy, @series)
    end

    test "a music-only user has no access" do
      refute ::Books::SeriesPolicy.new(music_user, @series).show?
    end

    test "Scope resolves for books readers only" do
      assert_books_scope(::Books::SeriesPolicy, ::Books::Series)
    end
  end
end
