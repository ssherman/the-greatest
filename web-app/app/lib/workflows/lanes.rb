# frozen_string_literal: true

# A run's "lane" option moves the steps that share a one-thread, paced queue
# onto that queue's priority twin, which Sidekiq drains first inside the same
# capsule (so the gate's one-thread safety holds). Every other queue and lane
# is left as declared.
module Workflows
  module Lanes
    PRIORITY = "priority"
    PRIORITY_QUEUES = %w[goodreads_fetch serial].freeze

    def self.queue_for(queue, lane)
      queue = queue.to_s
      (lane.to_s == PRIORITY && PRIORITY_QUEUES.include?(queue)) ? "#{queue}_priority" : queue
    end
  end
end
