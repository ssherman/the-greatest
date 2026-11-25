require "test_helper"

module Workflows
  class LanesTest < ActiveSupport::TestCase
    test "the priority lane moves goodreads_fetch and serial to their priority queues" do
      assert_equal "goodreads_fetch_priority", Lanes.queue_for(:goodreads_fetch, "priority")
      assert_equal "serial_priority", Lanes.queue_for("serial", "priority")
    end

    test "every other queue, and every other lane, is unchanged" do
      assert_equal "low", Lanes.queue_for(:low, "priority")
      assert_equal "goodreads_fetch", Lanes.queue_for(:goodreads_fetch, nil)
      assert_equal "serial", Lanes.queue_for(:serial, "other")
    end
  end
end
