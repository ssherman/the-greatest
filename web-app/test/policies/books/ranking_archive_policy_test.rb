require "test_helper"
require_relative "domain_policy_assertions"

module Books
  class RankingArchivePolicyTest < ActiveSupport::TestCase
    include Books::DomainPolicyAssertions

    setup do
      @series = ranking_archives(:books_january_2027)
    end

    test "domain is books" do
      assert_equal "books", ::Books::RankingArchivePolicy.new(users(:admin_user), @series).domain
    end

    test "grants access by global role and books domain role" do
      assert_books_domain_policy(::Books::RankingArchivePolicy, @series)
    end

    test "a music-only user has no access" do
      refute ::Books::RankingArchivePolicy.new(music_user, @series).show?
    end

    test "Scope resolves for books readers only" do
      assert_books_scope(::Books::RankingArchivePolicy, ::Books::RankingArchive)
    end
  end
end
