require "test_helper"

module Services
  module Books
    module ReadingGoals
      class CachedUrlsTest < ActiveSupport::TestCase
        setup do
          @goal = books_reading_goals(:public_goal_other_user)
        end

        test "enumerates base and every existing page for every configured Books host" do
          with_books_domain("books.test,books-alt.test") do
            urls = CachedUrls.call(goal: @goal, count: 49)

            assert_equal [
              "https://books.test/reading_goals/#{@goal.id}",
              "https://books.test/reading_goals/#{@goal.id}/page/2",
              "https://books.test/reading_goals/#{@goal.id}/page/3",
              "https://books-alt.test/reading_goals/#{@goal.id}",
              "https://books-alt.test/reading_goals/#{@goal.id}/page/2",
              "https://books-alt.test/reading_goals/#{@goal.id}/page/3"
            ], urls
          end
        end

        test "always includes the base page at zero and never emits page one" do
          with_books_domain("books.test") do
            assert_equal ["https://books.test/reading_goals/#{@goal.id}"],
              CachedUrls.call(goal: @goal, count: 0)
          end
        end

        test "uses the progress query page boundary" do
          with_books_domain("books.test") do
            assert_equal ["https://books.test/reading_goals/#{@goal.id}"],
              CachedUrls.call(goal: @goal, count: ProgressQuery::PER_PAGE)
            assert_equal [
              "https://books.test/reading_goals/#{@goal.id}",
              "https://books.test/reading_goals/#{@goal.id}/page/2"
            ], CachedUrls.call(goal: @goal, count: ProgressQuery::PER_PAGE + 1)
          end
        end

        test "splits hosts exactly like the router and removes duplicates" do
          with_books_domain("books.test,, books-alt.test,books.test") do
            assert_equal [
              "https://books.test/reading_goals/#{@goal.id}",
              "https:// books-alt.test/reading_goals/#{@goal.id}"
            ], CachedUrls.call(goal: @goal, count: nil)
          end
        end

        private

        def with_books_domain(value)
          original = Rails.application.config.domains[:books]
          Rails.application.config.domains[:books] = value
          yield
        ensure
          Rails.application.config.domains[:books] = original
        end
      end
    end
  end
end
