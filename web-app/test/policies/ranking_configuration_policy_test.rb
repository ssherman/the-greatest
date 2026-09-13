# frozen_string_literal: true

require "test_helper"

class RankingConfigurationPolicyTest < ActiveSupport::TestCase
  setup do
    @owner = users(:regular_user)
    @admin = users(:admin_user)
    @editor = users(:editor_user)
    @config = ranking_configurations(:books_user)
    @shared = ranking_configurations(:books_user_shared)
  end

  test "any signed-in user may list and create; anonymous may not" do
    assert RankingConfigurationPolicy.new(@editor, RankingConfiguration).index?
    assert RankingConfigurationPolicy.new(@editor, RankingConfiguration).create?
    assert RankingConfigurationPolicy.new(@editor, RankingConfiguration).new?
    refute RankingConfigurationPolicy.new(nil, RankingConfiguration).index?
    refute RankingConfigurationPolicy.new(nil, RankingConfiguration).create?
  end

  test "only the owner may manage a configuration, shared or not" do
    [:show?, :edit?, :update?, :destroy?, :refresh?, :state?, :manage_lists?].each do |action|
      assert RankingConfigurationPolicy.new(@owner, @config).public_send(action), action
      assert RankingConfigurationPolicy.new(@owner, @shared).public_send(action), action
      refute RankingConfigurationPolicy.new(@editor, @shared).public_send(action), "#{action}: a domain editor is not the owner"
      refute RankingConfigurationPolicy.new(@admin, @config).public_send(action), "#{action}: an admin is not the owner"
      refute RankingConfigurationPolicy.new(nil, @shared).public_send(action), action
    end
  end

  test "scope returns only the user's own rows" do
    assert_equal [@config.id, @shared.id].sort,
      RankingConfigurationPolicy::Scope.new(@owner, RankingConfiguration).resolve.pluck(:id).sort
    assert_empty RankingConfigurationPolicy::Scope.new(@admin, RankingConfiguration).resolve
    assert_empty RankingConfigurationPolicy::Scope.new(nil, RankingConfiguration).resolve
  end
end
