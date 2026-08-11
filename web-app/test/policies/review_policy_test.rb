require "test_helper"

class ReviewPolicyTest < ActiveSupport::TestCase
  setup do
    @owner = users(:regular_user)
    @other = users(:editor_user)
    @review = reviews(:regular_user_war_and_peace)
  end

  test "any signed-in user may create" do
    assert ReviewPolicy.new(@other, Review.new).create?
  end

  test "an anonymous visitor may not create" do
    refute ReviewPolicy.new(nil, Review.new).create?
  end

  test "the owner may update and destroy" do
    policy = ReviewPolicy.new(@owner, @review)

    assert policy.update?
    assert policy.destroy?
  end

  test "a different signed-in user may not update or destroy" do
    policy = ReviewPolicy.new(@other, @review)

    refute policy.update?
    refute policy.destroy?
  end

  test "an anonymous visitor may not update or destroy" do
    policy = ReviewPolicy.new(nil, @review)

    refute policy.update?
    refute policy.destroy?
  end

  test "the scope resolves to the user's own reviews" do
    resolved = ReviewPolicy::Scope.new(@owner, Review.all).resolve

    assert_includes resolved, @review
    refute_includes resolved, reviews(:editor_user_war_and_peace)
  end

  test "the scope is empty for an anonymous visitor" do
    assert_empty ReviewPolicy::Scope.new(nil, Review.all).resolve
  end
end
