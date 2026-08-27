module Services
  module Books
    module ReadingGoals
      class CompletionChangeInvalidator
        def self.call(user:, old_completed_on:, new_completed_on:)
          new(
            user: user,
            old_completed_on: old_completed_on,
            new_completed_on: new_completed_on
          ).call
        end

        def initialize(user:, old_completed_on:, new_completed_on:)
          @user = user
          @old_completed_on = old_completed_on
          @new_completed_on = new_completed_on
        end

        def call
          return [] if old_completed_on == new_completed_on

          urls = affected_goals.flat_map do |goal|
            after_count = ProgressQuery.call(goal: goal).count
            delta = (contains?(goal, new_completed_on) ? 1 : 0) -
              (contains?(goal, old_completed_on) ? 1 : 0)
            before_count = after_count - delta

            CachedUrls.call(goal: goal, count: before_count) +
              CachedUrls.call(goal: goal, count: after_count)
          end.uniq

          ::Books::ReadingGoals::PurgeCachedPagesJob.perform_async("books", urls) if urls.any?
          urls
        end

        private

        attr_reader :user, :old_completed_on, :new_completed_on

        def affected_goals
          scope = user.books_reading_goals.public_goals

          if old_completed_on && new_completed_on
            scope.where(
              "(starts_on <= ? AND ends_on >= ?) OR (starts_on <= ? AND ends_on >= ?)",
              old_completed_on, old_completed_on, new_completed_on, new_completed_on
            ).order(:id)
          else
            date = old_completed_on || new_completed_on
            return scope.none if date.nil?

            scope.where("starts_on <= ? AND ends_on >= ?", date, date).order(:id)
          end
        end

        def contains?(goal, date)
          date && goal.starts_on <= date && goal.ends_on >= date
        end
      end
    end
  end
end
