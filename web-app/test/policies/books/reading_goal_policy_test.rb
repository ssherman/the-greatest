require "test_helper"

module Books
  class ReadingGoalPolicyTest < ActiveSupport::TestCase
    setup do
      @owner = users(:regular_user)
      @admin = users(:admin_user)
      @other_user = users(:editor_user)
      @private_goal = books_reading_goals(:private_goal)
      @public_goal = books_reading_goals(:public_goal_other_user)
    end

    test "shows public goals to everyone and private goals to their owner or an admin" do
      assert ReadingGoalPolicy.new(nil, @public_goal).show?
      assert ReadingGoalPolicy.new(@other_user, @public_goal).show?
      assert ReadingGoalPolicy.new(@owner, @private_goal).show?
      assert ReadingGoalPolicy.new(@admin, @private_goal).show?
      refute ReadingGoalPolicy.new(nil, @private_goal).show?
      refute ReadingGoalPolicy.new(@other_user, @private_goal).show?
    end

    test "permits creation for signed in users and changes only for owner or admin" do
      assert ReadingGoalPolicy.new(@owner, @private_goal).create?
      assert ReadingGoalPolicy.new(@other_user, @private_goal).new?
      refute ReadingGoalPolicy.new(nil, @private_goal).create?

      [:edit?, :update?, :destroy?].each do |action|
        assert ReadingGoalPolicy.new(@owner, @private_goal).public_send(action)
        assert ReadingGoalPolicy.new(@admin, @private_goal).public_send(action)
        refute ReadingGoalPolicy.new(@other_user, @private_goal).public_send(action)
      end
    end

    test "scope gives admins every goal and other users only their own goals" do
      assert_equal Books::ReadingGoal.count,
        ReadingGoalPolicy::Scope.new(@admin, Books::ReadingGoal).resolve.count
      assert_equal [@private_goal.id],
        ReadingGoalPolicy::Scope.new(@owner, Books::ReadingGoal).resolve.where(id: @private_goal.id).pluck(:id)
      assert_empty ReadingGoalPolicy::Scope.new(nil, Books::ReadingGoal).resolve
    end
  end
end
