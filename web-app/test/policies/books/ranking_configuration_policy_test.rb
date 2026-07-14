require "test_helper"
require_relative "domain_policy_assertions"

module Books
  class RankingConfigurationPolicyTest < ActiveSupport::TestCase
    include Books::DomainPolicyAssertions

    setup do
      @rc = ranking_configurations(:books_global)
    end

    test "domain is books" do
      assert_equal "books", ::Books::RankingConfigurationPolicy.new(users(:admin_user), @rc).domain
    end

    test "reading is open to global roles and any books domain role" do
      assert ::Books::RankingConfigurationPolicy.new(users(:admin_user), @rc).index?
      assert ::Books::RankingConfigurationPolicy.new(users(:editor_user), @rc).show?
      assert ::Books::RankingConfigurationPolicy.new(books_user(:viewer), @rc).show?
      refute ::Books::RankingConfigurationPolicy.new(users(:regular_user), @rc).show?
    end

    test "writing requires manage, so a global editor is denied" do
      refute ::Books::RankingConfigurationPolicy.new(users(:editor_user), @rc).create?
      refute ::Books::RankingConfigurationPolicy.new(users(:editor_user), @rc).update?
      refute ::Books::RankingConfigurationPolicy.new(users(:editor_user), @rc).destroy?

      refute ::Books::RankingConfigurationPolicy.new(books_user(:moderator), @rc).update?

      assert ::Books::RankingConfigurationPolicy.new(users(:admin_user), @rc).update?
      assert ::Books::RankingConfigurationPolicy.new(books_user(:admin), @rc).update?
      assert ::Books::RankingConfigurationPolicy.new(books_user(:admin), @rc).destroy?
    end

    test "execute and index actions are open to writers" do
      assert ::Books::RankingConfigurationPolicy.new(users(:editor_user), @rc).execute_action?
      assert ::Books::RankingConfigurationPolicy.new(users(:editor_user), @rc).index_action?
      assert ::Books::RankingConfigurationPolicy.new(books_user(:editor), @rc).execute_action?
      refute ::Books::RankingConfigurationPolicy.new(books_user(:viewer), @rc).execute_action?
      refute ::Books::RankingConfigurationPolicy.new(music_user, @rc).execute_action?
    end

    test "Scope resolves for books readers only" do
      assert_books_scope(::Books::RankingConfigurationPolicy, ::Books::RankingConfiguration)
    end
  end
end
