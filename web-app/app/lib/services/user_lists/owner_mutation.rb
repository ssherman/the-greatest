module Services
  module UserLists
    # Runs a list mutation under the owner's row lock, which is also its transaction.
    # SaveGoal and DestroyGoal take the same owner-first lock before a reading-goal
    # lock, so keeping the write and the post-write goal counts inside it stops
    # another completion change interleaving. The Sidekiq push is deliberately
    # deferred to commit.
    #
    # requires_new: true gives a savepoint when a caller already holds a
    # transaction, so a raised BatchFailed undoes this batch and only this batch.
    class OwnerMutation
      class Tracker
        def initialize(owner)
          @owner = owner
          @urls = []
        end

        attr_reader :urls

        def change(old_completed_on:, new_completed_on:)
          @urls.concat(
            Services::Books::ReadingGoals::CompletionChangeInvalidator.call(
              user: @owner,
              old_completed_on: old_completed_on,
              new_completed_on: new_completed_on,
              enqueue: false
            )
          )
        end

        def track(result)
          return unless result.success? && result.data[:listable].is_a?(::Books::Book)

          change(old_completed_on: result.data[:old_completed_on], new_completed_on: result.data[:new_completed_on])
        end
      end

      def self.call(owner:, &block)
        tracker = Tracker.new(owner)
        value = owner.with_lock(requires_new: true) { block.call(tracker) }

        urls = tracker.urls.uniq
        if urls.any?
          ActiveRecord::Base.current_transaction.after_commit do
            ::Books::ReadingGoals::PurgeCachedPagesJob.perform_async("books", urls)
          end
        end
        value
      end
    end
  end
end
