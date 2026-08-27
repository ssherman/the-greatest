require "test_helper"

module Services
  module Books
    module ReadingGoals
      class DestroyGoalTest < ActiveSupport::TestCase
        setup do
          @user = users(:regular_user)
          @host = Rails.application.config.domains[:books]
        end

        test "destroys a public goal and then enqueues all of its old URLs" do
          goal = reading_goal(public: true)
          expected = ["https://#{@host}/reading_goals/#{goal.id}"]
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).with("books", expected)

          result = DestroyGoal.call(goal: goal)

          assert result.success?
          assert_equal goal, result.data[:goal]
          assert goal.destroyed?
          refute ::Books::ReadingGoal.exists?(goal.id)
        end

        test "destroys a private goal without enqueueing a purge" do
          goal = reading_goal(public: false)
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).never

          result = DestroyGoal.call(goal: goal)

          assert result.success?
          assert goal.destroyed?
        end

        test "a failed destroy returns errors and does not enqueue a purge" do
          goal = reading_goal(public: true)
          goal.expects(:destroy!).raises(ActiveRecord::RecordNotDestroyed.new("blocked", goal))
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).never

          result = DestroyGoal.call(goal: goal)

          refute result.success?
          assert_equal goal, result.data[:goal]
          assert_includes result.errors, "blocked"
          assert ::Books::ReadingGoal.exists?(goal.id)
        end

        private

        def reading_goal(public:)
          ::Books::ReadingGoal.create!(
            user: @user,
            name: "Destroy me",
            target_count: 12,
            starts_on: Date.new(2028, 1, 1),
            ends_on: Date.new(2028, 12, 31),
            public: public
          )
        end
      end
    end
  end
end
