require "test_helper"

module Services
  module Books
    module ReadingGoals
      class SaveGoalTest < ActiveSupport::TestCase
        setup do
          @user = users(:regular_user)
          @host = Rails.application.config.domains[:books]
        end

        test "creates a public goal and asynchronously purges its public page" do
          goal = ::Books::ReadingGoal.new(user: @user)

          Sidekiq::Testing.fake! do
            result = SaveGoal.call(goal: goal, attributes: valid_attributes(public: true))

            assert result.success?
            assert result.data[:persisted]
            assert_nil result.data[:purge_confirmed]
            assert goal.persisted?
            assert_equal ["books", [goal_url(goal)]],
              ::Books::ReadingGoals::PurgeCachedPagesJob.jobs.last.fetch("args")
          end
        end

        test "updates a public goal by enqueueing the before and after URL union" do
          goal = public_goal
          25.times { |index| add_read_item(goal.starts_on, title: "Before #{index}") }
          expected = [goal_url(goal), "#{goal_url(goal)}/page/2"]
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).with("books", expected)

          result = SaveGoal.call(
            goal: goal,
            attributes: {starts_on: Date.new(2027, 1, 1), ends_on: Date.new(2027, 12, 31)}
          )

          assert result.success?
          assert_equal Date.new(2027, 1, 1), goal.reload.starts_on
        end

        test "does not purge when validation fails" do
          goal = public_goal
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).never
          Cloudflare::PurgeService.expects(:new).never

          result = SaveGoal.call(goal: goal, attributes: {name: ""})

          refute result.success?
          refute result.data[:persisted]
          assert_nil result.data[:purge_confirmed]
          assert_includes result.errors, "Name can't be blank"
          refute_equal "", goal.reload.name
        end

        test "private goal updates do not enqueue a purge" do
          goal = public_goal(public: false)
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).never
          Cloudflare::PurgeService.expects(:new).never

          result = SaveGoal.call(goal: goal, attributes: {name: "Still private"})

          assert result.success?
          assert_equal "Still private", goal.reload.name
        end

        test "public to private saves origin first and synchronously purges every old URL" do
          goal = public_goal
          urls = Array.new(101) { |index| "https://books.test/reading_goals/#{goal.id}/variant/#{index}" }
          CachedUrls.expects(:call).with(goal: goal, count: 0).returns(urls)
          batches = []
          purge = Object.new
          purge.define_singleton_method(:purge_urls) do |domain, batch|
            raise "wrong domain" unless domain == :books
            raise "origin is still public" if goal.reload.public?

            batches << batch
            {success: true}
          end
          Cloudflare::PurgeService.stubs(:new).returns(purge)
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).never

          result = with_purge_token do
            SaveGoal.call(goal: goal, attributes: {public: false})
          end

          assert result.success?
          refute goal.reload.public?
          assert result.data[:persisted]
          assert result.data[:purge_confirmed]
          assert_equal [urls.first(100), urls.last(1)], batches
        end

        test "missing token in test confirms privacy revocation without constructing Configuration" do
          goal = public_goal
          Cloudflare::Configuration.expects(:new).never
          Cloudflare::PurgeService.expects(:new).never
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).never

          result = without_purge_token do
            SaveGoal.call(goal: goal, attributes: {public: false})
          end

          assert result.success?
          refute goal.reload.public?
          assert result.data[:purge_confirmed]
        end

        test "failed synchronous revocation persists privacy and queues the old URLs for retry" do
          goal = public_goal
          urls = [goal_url(goal)]
          purge = mock("purge")
          purge.expects(:purge_urls).with(:books, urls).returns(success: false, error: "edge unavailable")
          Cloudflare::PurgeService.stubs(:new).returns(purge)

          Sidekiq::Testing.fake! do
            result = with_purge_token do
              SaveGoal.call(goal: goal, attributes: {public: false})
            end

            refute result.success?
            refute goal.reload.public?
            assert result.data[:persisted]
            refute result.data[:purge_confirmed]
            assert_includes result.errors, "edge unavailable"
            assert_equal ["books", urls],
              ::Books::ReadingGoals::PurgeCachedPagesJob.jobs.last.fetch("args")
          end
        end

        private

        def valid_attributes(**attributes)
          {
            name: "New public goal",
            target_count: 12,
            starts_on: Date.new(2028, 1, 1),
            ends_on: Date.new(2028, 12, 31),
            public: false
          }.merge(attributes)
        end

        def public_goal(**attributes)
          ::Books::ReadingGoal.create!(valid_attributes(public: true).merge(attributes).merge(user: @user))
        end

        def add_read_item(completed_on, title:)
          book = ::Books::Book.create!(title: title, slug: "save-goal-#{SecureRandom.hex(8)}")
          user_lists(:regular_user_books_read).user_list_items.create!(
            listable: book, completed_on: completed_on
          )
        end

        def goal_url(goal)
          "https://#{@host}/reading_goals/#{goal.id}"
        end

        def with_purge_token
          with_env("CLOUDFLARE_CACHE_PURGE_TOKEN" => "test-token") { yield }
        end

        def without_purge_token
          with_env("CLOUDFLARE_CACHE_PURGE_TOKEN" => nil) { yield }
        end
      end
    end
  end
end
