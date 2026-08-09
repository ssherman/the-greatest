# frozen_string_literal: true

require "test_helper"

class SavedSearchPolicyTest < ActiveSupport::TestCase
  def setup
    @owner = users(:regular_user)
    @other = users(:admin_user)
    @public_search = saved_searches(:books_public)
    @private_search = saved_searches(:books_private)
  end

  test "anyone may reach the index" do
    assert SavedSearchPolicy.new(nil, SavedSearch).index?
  end

  test "the owner may view their private search" do
    assert SavedSearchPolicy.new(@owner, @private_search).show?
  end

  test "another user may not view a private search" do
    refute SavedSearchPolicy.new(@other, @private_search).show?
  end

  test "an anonymous viewer may not view a private search" do
    refute SavedSearchPolicy.new(nil, @private_search).show?
  end

  test "anyone may view a public search" do
    assert SavedSearchPolicy.new(nil, @public_search).show?
    assert SavedSearchPolicy.new(@other, @public_search).show?
  end

  test "a signed-in user may create; anonymous may not" do
    assert SavedSearchPolicy.new(@owner, SavedSearch.new).create?
    refute SavedSearchPolicy.new(nil, SavedSearch.new).create?
  end

  test "only the owner may update or destroy" do
    assert SavedSearchPolicy.new(@owner, @private_search).update?
    assert SavedSearchPolicy.new(@owner, @private_search).destroy?
    refute SavedSearchPolicy.new(@other, @private_search).update?
    refute SavedSearchPolicy.new(@other, @private_search).destroy?
  end

  test "another user may not update a PUBLIC search either" do
    refute SavedSearchPolicy.new(@other, @public_search).update?
    refute SavedSearchPolicy.new(@other, @public_search).destroy?
  end

  test "new? and edit? track create? and update?" do
    assert_equal SavedSearchPolicy.new(@owner, SavedSearch.new).create?,
      SavedSearchPolicy.new(@owner, SavedSearch.new).new?
    assert_equal SavedSearchPolicy.new(@other, @private_search).update?,
      SavedSearchPolicy.new(@other, @private_search).edit?
  end

  test "an anonymous viewer is not the owner of an unpersisted search" do
    refute SavedSearchPolicy.new(nil, SavedSearch.new).update?
    refute SavedSearchPolicy.new(nil, SavedSearch.new).destroy?
    refute SavedSearchPolicy.new(nil, SavedSearch.new).show?
  end

  test "the owner's scope includes their own private search plus public ones" do
    resolved = SavedSearchPolicy::Scope.new(@owner, SavedSearch).resolve

    assert_includes resolved, @private_search
    assert_includes resolved, @public_search
  end

  test "a non-owner's scope excludes someone else's private search" do
    resolved = SavedSearchPolicy::Scope.new(users(:editor_user), SavedSearch).resolve

    refute_includes resolved, @private_search
  end

  test "an admin's scope excludes another user's private search" do
    # This is the case the inherited ApplicationPolicy::Scope default gets wrong:
    # it treats admin/editor as a global bypass and would return scope.all.
    resolved = SavedSearchPolicy::Scope.new(@other, SavedSearch).resolve

    refute_includes resolved, @private_search
  end

  test "an anonymous viewer's scope includes only public searches" do
    resolved = SavedSearchPolicy::Scope.new(nil, SavedSearch).resolve

    assert_includes resolved, @public_search
    refute_includes resolved, @private_search
  end
end
