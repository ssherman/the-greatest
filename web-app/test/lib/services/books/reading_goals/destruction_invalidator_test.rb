require "test_helper"

module Services
  module Books
    module ReadingGoals
      class DestructionInvalidatorTest < ActiveSupport::TestCase
        setup do
          @user = users(:regular_user)
          @completed_on = Date.new(2026, 8, 29)
        end

        test "locks Books Read owners before capturing a deleted book's cached goal URLs" do
          book = ::Books::Book.create!(title: "Locking deletion book", book_kind: "standalone")
          user_lists(:regular_user_books_read).user_list_items.create!(listable: book, completed_on: @completed_on)
          goal = reading_goal

          locks = capture_user_locks do
            assert_equal [goal_url(goal)], DestructionInvalidator.for_book(book: book)
          end

          assert_equal ["users"], locks
        end

        test "locks owners with undated Books Read entries before capturing URLs" do
          book = ::Books::Book.create!(title: "Undated locking deletion book", book_kind: "standalone")
          user_lists(:regular_user_books_read).user_list_items.create!(listable: book, completed_on: nil)

          locks = capture_user_locks do
            assert_equal [], DestructionInvalidator.for_book(book: book)
          end

          assert_equal ["users"], locks
        end

        test "locks a deleted goal owner before capturing their cached goal URLs" do
          goal = reading_goal

          locks = capture_user_locks do
            assert_equal [goal_url(goal)], DestructionInvalidator.for_user(user: @user)
          end

          assert_equal ["users"], locks
        end

        private

        def reading_goal
          ::Books::ReadingGoal.create!(
            user: @user,
            name: "Locking goal",
            target_count: 12,
            starts_on: @completed_on,
            ends_on: @completed_on,
            public: true
          )
        end

        def goal_url(goal)
          "https://#{Rails.application.config.domains[:books]}/reading_goals/#{goal.id}"
        end

        def capture_user_locks
          locks = []
          subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
            sql = payload[:sql]
            locks << "users" if sql.include?("FOR UPDATE") && sql.match?(/FROM "users"/)
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
