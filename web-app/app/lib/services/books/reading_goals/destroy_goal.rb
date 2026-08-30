module Services
  module Books
    module ReadingGoals
      class DestroyGoal
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(goal:)
          new(goal: goal).call
        end

        def initialize(goal:)
          @goal = goal
        end

        def call
          goal.class.transaction do |transaction|
            urls = capture_and_destroy
            transaction.after_commit do
              ::Books::ReadingGoals::PurgeCachedPagesJob.perform_async("books", urls) if urls.any?
            end
          end

          Result.new(success?: true, data: {goal: goal}, errors: [])
        rescue ActiveRecord::RecordNotDestroyed => error
          Result.new(success?: false, data: {goal: goal}, errors: failure_errors(error))
        rescue ActiveRecord::RecordNotFound
          Result.new(success?: false, data: {goal: goal}, errors: ["Reading goal no longer exists"])
        end

        private

        attr_reader :goal

        # Match SaveGoal and completion writes: owner first, then goal. The
        # reload under lock makes a stale caller observe the database's current
        # privacy and range before the row disappears.
        def capture_and_destroy
          owner_id = goal.class.where(id: goal.id).pick(:user_id)
          ::User.lock.find(owner_id)
          goal.reload(lock: true)
          urls = goal.public? ? cached_urls : []
          goal.destroy!
          urls
        end

        def cached_urls
          count = ProgressQuery.call(goal: goal).count
          CachedUrls.call(goal: goal, count: count)
        end

        def failure_errors(error)
          goal.errors.full_messages.presence || [error.message]
        end
      end
    end
  end
end
