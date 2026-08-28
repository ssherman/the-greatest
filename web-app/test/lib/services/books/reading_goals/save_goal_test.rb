require "test_helper"

module Services
  module Books
    module ReadingGoals
      class SaveGoalTest < ActiveSupport::TestCase
        self.use_transactional_tests = false

        setup do
          @user = users(:regular_user)
          @host = Rails.application.config.domains[:books]
          ::Books::ReadingGoals::PurgeCachedPagesJob.clear
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
          transaction_depth = ActiveRecord::Base.connection.open_transactions
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).with do |domain, urls|
            assert_equal transaction_depth, ActiveRecord::Base.connection.open_transactions,
              "enqueue must happen after the goal transaction exits"
            domain == "books" && urls == expected
          end

          result = SaveGoal.call(
            goal: goal,
            attributes: {starts_on: Date.new(2027, 1, 1), ends_on: Date.new(2027, 12, 31)}
          )

          assert result.success?
          assert_equal Date.new(2027, 1, 1), goal.reload.starts_on
        end

        test "defers an async purge until an enclosing transaction commits" do
          goal = public_goal

          Sidekiq::Testing.fake! do
            ::Books::ReadingGoal.transaction do
              result = SaveGoal.call(goal: goal, attributes: {name: "Committed later"})

              assert result.success?
              assert_empty ::Books::ReadingGoals::PurgeCachedPagesJob.jobs
            end

            assert_equal ["books", [goal_url(goal)]],
              ::Books::ReadingGoals::PurgeCachedPagesJob.jobs.last.fetch("args")
          end
        end

        test "drops an async purge when an enclosing transaction rolls back" do
          goal = public_goal

          Sidekiq::Testing.fake! do
            ::Books::ReadingGoal.transaction do
              SaveGoal.call(goal: goal, attributes: {name: "Rolled back"})
              assert_empty ::Books::ReadingGoals::PurgeCachedPagesJob.jobs
              raise ActiveRecord::Rollback
            end

            assert_empty ::Books::ReadingGoals::PurgeCachedPagesJob.jobs
            refute_equal "Rolled back", goal.reload.name
          end
        end

        test "defers privacy revocation until an enclosing transaction commits" do
          goal = public_goal
          calls = []
          purge = Object.new
          purge.define_singleton_method(:purge_urls) do |domain, urls|
            calls << [domain, urls]
            {success: true}
          end
          Cloudflare::PurgeService.stubs(:new).returns(purge)

          result = with_purge_token do
            ::Books::ReadingGoal.transaction do
              nested_result = SaveGoal.call(goal: goal, attributes: {public: false})
              assert nested_result.success?
              assert_nil nested_result.data[:purge_confirmed]
              assert_empty calls
              nested_result
            end
          end

          assert_equal [[:books, [goal_url(goal)]]], calls
          refute goal.reload.public?
          assert result.success?
        end

        test "drops privacy revocation when an enclosing transaction rolls back" do
          goal = public_goal
          calls = []
          purge = Object.new
          purge.define_singleton_method(:purge_urls) do |domain, urls|
            calls << [domain, urls]
            {success: true}
          end
          Cloudflare::PurgeService.stubs(:new).returns(purge)

          with_purge_token do
            ::Books::ReadingGoal.transaction do
              SaveGoal.call(goal: goal, attributes: {public: false})
              assert_empty calls
              raise ActiveRecord::Rollback
            end
          end

          assert_empty calls
          assert goal.reload.public?
        end

        test "a concurrently deleted goal returns a failure without purging" do
          goal = public_goal
          ::Books::ReadingGoal.where(id: goal.id).delete_all
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).never
          Cloudflare::PurgeService.expects(:new).never

          result = SaveGoal.call(goal: goal, attributes: {name: "Too late"})

          refute result.success?
          refute result.data[:persisted]
          assert_nil result.data[:purge_confirmed]
          assert_equal ["Reading goal no longer exists"], result.errors
        end

        test "reloads a stale private instance before revoking a currently public goal" do
          goal = public_goal(public: false)
          ::Books::ReadingGoal.where(id: goal.id).update_all(public: true) # rubocop:disable Rails/SkipsModelValidations
          purge = mock("purge")
          purge.expects(:purge_urls).with(:books, [goal_url(goal)]).returns(success: true)
          Cloudflare::PurgeService.stubs(:new).returns(purge)
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).never

          result = with_purge_token do
            SaveGoal.call(goal: goal, attributes: {public: false})
          end

          assert result.success?
          refute goal.reload.public?
          assert result.data[:purge_confirmed]
        end

        test "uses the current database range when a stale instance hides an old second page" do
          goal = public_goal(starts_on: Date.new(2027, 1, 1), ends_on: Date.new(2027, 12, 31))
          goal.update_columns(starts_on: Date.new(2026, 1, 1), ends_on: Date.new(2026, 12, 31))
          stale_goal = ::Books::ReadingGoal.find(goal.id)
          stale_goal.starts_on = Date.new(2027, 1, 1)
          stale_goal.ends_on = Date.new(2027, 12, 31)
          stale_goal.clear_changes_information
          25.times { |index| add_read_item(Date.new(2026, 6, 1), title: "Stale range #{index}") }
          expected = [goal_url(goal), "#{goal_url(goal)}/page/2"]
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).with("books", expected)

          result = SaveGoal.call(goal: stale_goal, attributes: {name: "Current-range update"})

          assert result.success?
          assert_equal Date.new(2026, 1, 1), stale_goal.reload.starts_on
        end

        test "a stale public instance does not add old pages to a current private to public update" do
          goal = public_goal(starts_on: Date.new(2026, 1, 1), ends_on: Date.new(2026, 12, 31))
          25.times { |index| add_read_item(Date.new(2026, 6, 1), title: "Old private range #{index}") }
          stale_goal = ::Books::ReadingGoal.find(goal.id)
          goal.update_columns(public: false, starts_on: Date.new(2027, 1, 1), ends_on: Date.new(2027, 12, 31))
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async)
            .with("books", [goal_url(goal)])

          result = SaveGoal.call(goal: stale_goal, attributes: {public: true})

          assert result.success?
          assert stale_goal.reload.public?
          assert_equal Date.new(2027, 1, 1), stale_goal.starts_on
        end

        test "locks the current owner before the reading goal" do
          goal = public_goal
          ::Books::ReadingGoals::PurgeCachedPagesJob.stubs(:perform_async)
          locks = capture_row_locks do
            SaveGoal.call(goal: goal, attributes: {name: "Locked update"})
          end

          assert_equal ["users", "books_reading_goals"], locks
        end

        test "locks a new goal's owner while saving and counting" do
          goal = ::Books::ReadingGoal.new(user: @user)
          ::Books::ReadingGoals::PurgeCachedPagesJob.stubs(:perform_async)
          locks = capture_row_locks do
            SaveGoal.call(goal: goal, attributes: valid_attributes(public: true))
          end

          assert_equal ["users"], locks
          assert goal.persisted?
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
          transaction_depth = ActiveRecord::Base.connection.open_transactions
          purge = Object.new
          purge.define_singleton_method(:purge_urls) do |domain, batch|
            raise "wrong domain" unless domain == :books
            raise "origin is still public" if goal.reload.public?
            raise "goal transaction is still open" unless ActiveRecord::Base.connection.open_transactions == transaction_depth

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

        test "a partial synchronous revocation failure retries the full old URL set" do
          goal = public_goal
          urls = Array.new(101) { |index| "https://books.test/reading_goals/#{goal.id}/variant/#{index}" }
          CachedUrls.expects(:call).with(goal: goal, count: 0).returns(urls)
          purge = mock("purge")
          purge.expects(:purge_urls).with(:books, urls.first(100)).returns(success: true)
          purge.expects(:purge_urls).with(:books, urls.last(1)).returns(success: false, error: "second batch failed")
          Cloudflare::PurgeService.stubs(:new).returns(purge)

          Sidekiq::Testing.fake! do
            result = with_purge_token do
              SaveGoal.call(goal: goal, attributes: {public: false})
            end

            refute result.success?
            refute goal.reload.public?
            assert result.data[:persisted]
            refute result.data[:purge_confirmed]
            assert_equal ["books", urls],
              ::Books::ReadingGoals::PurgeCachedPagesJob.jobs.last.fetch("args")
          end
        end

        test "a synchronous purge exception persists privacy and retries the full old URL set" do
          goal = public_goal
          urls = Array.new(101) { |index| "https://books.test/reading_goals/#{goal.id}/variant/#{index}" }
          CachedUrls.expects(:call).with(goal: goal, count: 0).returns(urls)
          purge = mock("purge")
          purge.expects(:purge_urls).with(:books, urls.first(100)).returns(success: true)
          purge.expects(:purge_urls).with(:books, urls.last(1)).raises(StandardError.new("connection reset"))
          Cloudflare::PurgeService.stubs(:new).returns(purge)

          Sidekiq::Testing.fake! do
            result = with_purge_token do
              SaveGoal.call(goal: goal, attributes: {public: false})
            end

            refute result.success?
            refute goal.reload.public?
            assert result.data[:persisted]
            refute result.data[:purge_confirmed]
            assert_includes result.errors, "connection reset"
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
