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
          urls = goal.public? ? cached_urls : []
          goal.destroy!
          ::Books::ReadingGoals::PurgeCachedPagesJob.perform_async("books", urls) if urls.any?

          Result.new(success?: true, data: {goal: goal}, errors: [])
        rescue ActiveRecord::RecordNotDestroyed => error
          Result.new(success?: false, data: {goal: goal}, errors: failure_errors(error))
        end

        private

        attr_reader :goal

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
