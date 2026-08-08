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
end
