require "test_helper"

module Games
  class GamePolicyTest < ActiveSupport::TestCase
    setup do
      @game = games_games(:breath_of_the_wild)
    end

    test "a domain editor cannot execute admin actions" do
      policy = ::Games::GamePolicy.new(users(:games_editor_user), @game)

      assert policy.update?, "an editor should still be able to edit"
      assert_not policy.destroy?
      assert_not policy.execute_action?,
        "merge deletes a record, so write access must not be enough"
    end

    test "a domain moderator can execute admin actions" do
      policy = ::Games::GamePolicy.new(users(:games_moderator_user), @game)

      assert policy.destroy?
      assert policy.execute_action?
    end

    test "a global admin can execute admin actions" do
      assert ::Games::GamePolicy.new(users(:admin_user), @game).execute_action?
    end
  end
end
