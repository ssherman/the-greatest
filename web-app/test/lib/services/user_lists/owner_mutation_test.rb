require "test_helper"

module Services
  module UserLists
    class OwnerMutationTest < ActiveSupport::TestCase
      setup do
        @owner = users(:regular_user)
      end

      def result_for(listable, old_on: nil, new_on: Date.new(2026, 1, 1))
        MutationResult.new(
          success?: true,
          data: {listable: listable, old_completed_on: old_on, new_completed_on: new_on},
          errors: []
        )
      end

      test "tracks only book listables and enqueues one purge with unique urls" do
        Services::Books::ReadingGoals::CompletionChangeInvalidator.expects(:call).twice.returns(["/x"])
        ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).with("books", ["/x"]).once

        value = OwnerMutation.call(owner: @owner) do |tracker|
          tracker.track(result_for(books_books(:war_and_peace)))
          tracker.track(result_for(books_books(:crime_and_punishment)))
          tracker.track(result_for(music_albums(:dark_side_of_the_moon)))
          tracker.track(MutationResult.failure(["no"]))
          :done
        end

        assert_equal :done, value
      end

      test "enqueues nothing when there are no urls" do
        Services::Books::ReadingGoals::CompletionChangeInvalidator.stubs(:call).returns([])
        ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).never

        OwnerMutation.call(owner: @owner) { |tracker| tracker.change(old_completed_on: nil, new_completed_on: Date.new(2026, 1, 1)) }
      end

      test "an exception re-raises and enqueues nothing" do
        Services::Books::ReadingGoals::CompletionChangeInvalidator.stubs(:call).returns(["/x"])
        ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).never

        assert_raises(BatchFailed) do
          OwnerMutation.call(owner: @owner) do |tracker|
            tracker.change(old_completed_on: nil, new_completed_on: Date.new(2026, 1, 1))
            raise BatchFailed.new(["boom"])
          end
        end
      end
    end
  end
end
