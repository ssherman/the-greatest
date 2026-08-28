require "test_helper"

module Services
  module Books
    module ReadingGoals
      class DestroyGoalTest < ActiveSupport::TestCase
        self.use_transactional_tests = false

        setup do
          @user = users(:regular_user)
          @host = Rails.application.config.domains[:books]
          ::Books::ReadingGoals::PurgeCachedPagesJob.clear
        end

        test "destroys a public goal and then enqueues all of its old URLs" do
          goal = reading_goal(public: true)
          expected = ["https://#{@host}/reading_goals/#{goal.id}"]
          transaction_depth = ActiveRecord::Base.connection.open_transactions
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).with do |domain, urls|
            assert_equal transaction_depth, ActiveRecord::Base.connection.open_transactions,
              "enqueue must happen after the destroy transaction exits"
            domain == "books" && urls == expected
          end

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

        test "defers the purge until an enclosing transaction commits" do
          goal = reading_goal(public: true)

          Sidekiq::Testing.fake! do
            ::Books::ReadingGoal.transaction do
              result = DestroyGoal.call(goal: goal)

              assert result.success?
              assert_empty ::Books::ReadingGoals::PurgeCachedPagesJob.jobs
            end

            assert_equal ["books", ["https://#{@host}/reading_goals/#{goal.id}"]],
              ::Books::ReadingGoals::PurgeCachedPagesJob.jobs.last.fetch("args")
          end
        end

        test "drops the purge when an enclosing transaction rolls back" do
          goal = reading_goal(public: true)

          Sidekiq::Testing.fake! do
            ::Books::ReadingGoal.transaction do
              DestroyGoal.call(goal: goal)
              assert_empty ::Books::ReadingGoals::PurgeCachedPagesJob.jobs
              raise ActiveRecord::Rollback
            end

            assert_empty ::Books::ReadingGoals::PurgeCachedPagesJob.jobs
            assert ::Books::ReadingGoal.exists?(goal.id)
          end
        end

        test "a concurrently deleted goal returns a failure without purging" do
          goal = reading_goal(public: true)
          ::Books::ReadingGoal.where(id: goal.id).delete_all
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).never

          result = DestroyGoal.call(goal: goal)

          refute result.success?
          assert_equal goal, result.data[:goal]
          assert_equal ["Reading goal no longer exists"], result.errors
        end

        test "reloads a stale private instance before destroying a currently public goal" do
          goal = reading_goal(public: false)
          ::Books::ReadingGoal.where(id: goal.id).update_all(public: true) # rubocop:disable Rails/SkipsModelValidations
          expected = ["https://#{@host}/reading_goals/#{goal.id}"]
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).with("books", expected)

          result = DestroyGoal.call(goal: goal)

          assert result.success?
          assert goal.destroyed?
        end

        test "locks the current owner before the reading goal" do
          goal = reading_goal(public: true)
          ::Books::ReadingGoals::PurgeCachedPagesJob.stubs(:perform_async)
          locks = capture_row_locks { DestroyGoal.call(goal: goal) }

          assert_equal ["users", "books_reading_goals"], locks
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

        def capture_row_locks
          locks = []
          subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
            sql = payload[:sql]
            next unless sql.include?("FOR UPDATE")

            locks << "users" if sql.match?(/FROM "users"/)
            locks << "books_reading_goals" if sql.match?(/FROM "books_reading_goals"/)
          end
          yield
          locks
        ensure
          ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
        end
      end
    end
  end
end
