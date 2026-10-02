# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class QueuedChainTest < ActiveSupport::TestCase
        # CI has no Redis: the Sidekiq sets are stubbed with plain lists.
        def job(klass, *args) = stub(klass: klass, args: args)

        def setup
          ::Sidekiq::ScheduledSet.stubs(:new).returns([job("Books::Authors::WikidataJob", 1, false, false, false), job("Books::EnrichBookJob", 2)])
          ::Sidekiq::RetrySet.stubs(:new).returns([job("Books::Authors::EnrichJob", 3, false)])
          ::Sidekiq::Queue.stubs(:new).with("low").returns([job("Books::Authors::ViafJob", 4, false, true, false)])
        end

        test "collects the authors of chain jobs scheduled, retrying or enqueued on the low queue" do
          assert_equal({"Books::Authors::WikidataJob" => [1], "Books::Authors::ViafJob" => [4], "Books::Authors::EnrichJob" => [3]},
            QueuedChain.by_job)
          assert_equal Set[1, 3, 4], QueuedChain.author_ids
        end
      end
    end
  end
end
