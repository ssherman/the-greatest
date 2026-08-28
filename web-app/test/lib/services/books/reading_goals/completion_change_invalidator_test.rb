require "test_helper"

module Services
  module Books
    module ReadingGoals
      class CompletionChangeInvalidatorTest < ActiveSupport::TestCase
        setup do
          @user = users(:regular_user)
          @host = Rails.application.config.domains[:books]
        end

        test "a completion moving between ranges purges both affected public goals" do
          old_goal = public_goal(name: "Old", starts_on: Date.new(2025, 1, 1), ends_on: Date.new(2025, 12, 31))
          new_goal = public_goal(name: "New", starts_on: Date.new(2026, 1, 1), ends_on: Date.new(2026, 12, 31))
          add_read_item(Date.new(2026, 1, 1))
          expected = [goal_url(old_goal), goal_url(new_goal)]
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).with("books", expected)

          urls = CompletionChangeInvalidator.call(
            user: @user,
            old_completed_on: Date.new(2025, 12, 31),
            new_completed_on: Date.new(2026, 1, 1)
          )

          assert_equal expected, urls
        end

        test "a date change inside one range purges that public goal once" do
          goal = public_goal(starts_on: Date.new(2026, 1, 1), ends_on: Date.new(2026, 12, 31))
          add_read_item(Date.new(2026, 2, 1))
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async)
            .with("books", [goal_url(goal)])

          urls = CompletionChangeInvalidator.call(
            user: @user,
            old_completed_on: Date.new(2026, 1, 1),
            new_completed_on: Date.new(2026, 2, 1)
          )

          assert_equal [goal_url(goal)], urls
        end

        test "a count dropping from 25 to 24 retains the old second page" do
          goal = public_goal(starts_on: Date.new(2026, 1, 1), ends_on: Date.new(2026, 12, 31))
          24.times { |index| add_read_item(Date.new(2026, 1, 1), title: "Boundary #{index}") }
          expected = [goal_url(goal), "#{goal_url(goal)}/page/2"]
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).with("books", expected)

          urls = CompletionChangeInvalidator.call(
            user: @user,
            old_completed_on: Date.new(2026, 1, 1),
            new_completed_on: Date.new(2027, 1, 1)
          )

          assert_equal expected, urls
        end

        test "only public goals owned by the user and containing an affected date are purged" do
          included = public_goal(starts_on: Date.new(2026, 1, 1), ends_on: Date.new(2026, 12, 31))
          public_goal(name: "Unrelated", starts_on: Date.new(2027, 1, 1), ends_on: Date.new(2027, 12, 31))
          public_goal(name: "Private", starts_on: Date.new(2026, 1, 1), ends_on: Date.new(2026, 12, 31), public: false)
          public_goal(
            name: "Other owner", user: users(:admin_user),
            starts_on: Date.new(2026, 1, 1), ends_on: Date.new(2026, 12, 31)
          )
          add_read_item(Date.new(2026, 6, 1))
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async)
            .with("books", [goal_url(included)])

          urls = CompletionChangeInvalidator.call(
            user: @user, old_completed_on: nil, new_completed_on: Date.new(2026, 6, 1)
          )

          assert_equal [goal_url(included)], urls
        end

        test "nil and unchanged completion dates are no-ops" do
          public_goal(starts_on: Date.new(2026, 1, 1), ends_on: Date.new(2026, 12, 31))
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).never

          assert_empty CompletionChangeInvalidator.call(
            user: @user, old_completed_on: nil, new_completed_on: nil
          )
          assert_empty CompletionChangeInvalidator.call(
            user: @user,
            old_completed_on: Date.new(2026, 1, 1),
            new_completed_on: Date.new(2026, 1, 1)
          )
        end

        test "enqueues JSON-native arguments" do
          goal = public_goal(starts_on: Date.new(2026, 1, 1), ends_on: Date.new(2026, 12, 31))
          add_read_item(Date.new(2026, 6, 1))

          Sidekiq::Testing.fake! do
            CompletionChangeInvalidator.call(
              user: @user, old_completed_on: nil, new_completed_on: Date.new(2026, 6, 1)
            )

            args = ::Books::ReadingGoals::PurgeCachedPagesJob.jobs.last.fetch("args")
            assert_equal ["books", [goal_url(goal)]], args
            assert args.flatten.all? { |argument| argument.is_a?(String) }
          end
        end

        test "can return URLs without enqueueing for a caller-owned transaction" do
          goal = public_goal(starts_on: Date.new(2026, 1, 1), ends_on: Date.new(2026, 12, 31))
          add_read_item(Date.new(2026, 6, 1))
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).never

          urls = CompletionChangeInvalidator.call(
            user: @user,
            old_completed_on: nil,
            new_completed_on: Date.new(2026, 6, 1),
            enqueue: false
          )

          assert_equal [goal_url(goal)], urls
        end

        private

        def public_goal(**attributes)
          ::Books::ReadingGoal.create!({
            user: @user,
            name: "Public goal",
            target_count: 12,
            starts_on: Date.new(2026, 1, 1),
            ends_on: Date.new(2026, 12, 31),
            public: true
          }.merge(attributes))
        end

        def add_read_item(completed_on, title: SecureRandom.hex(6))
          book = ::Books::Book.create!(title: title, slug: "goal-#{SecureRandom.hex(8)}")
          user_lists(:regular_user_books_read).user_list_items.create!(
            listable: book, completed_on: completed_on
          )
        end

        def goal_url(goal)
          "https://#{@host}/reading_goals/#{goal.id}"
        end
      end
    end
  end
end
