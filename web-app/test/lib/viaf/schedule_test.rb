# frozen_string_literal: true

require "test_helper"

class Viaf::ScheduleTest < ActiveSupport::TestCase
  # CI has no Redis; FakeRedis models the hash commands and expiry.
  def setup
    freeze_time
    @schedule = Viaf::Schedule.new(redis: Books::OpenLibrary::FakeRedis.new)
  end

  test "an empty line starts a job after the wait it asked for" do
    assert_equal 30, @schedule.reserve(not_before: 30)
  end

  test "each waiting job starts one slot after the one before" do
    assert_equal [30, 120, 210], 3.times.map { @schedule.reserve(not_before: 30) }
  end

  test "a pause pushes the line to the end of the pause, and the next job queues behind it" do
    @schedule.reserve(not_before: 30)

    assert_equal [3600, 3690], [@schedule.reserve(not_before: 3600), @schedule.reserve(not_before: 30)]
  end

  test "once the line has run, the next job waits only its own wait" do
    2.times { @schedule.reserve(not_before: 30) }
    travel 1.hour

    assert_equal 30, @schedule.reserve(not_before: 30)
  end

  test "the horizon is the last start given out, and nil once it has passed" do
    assert_nil @schedule.horizon
    2.times { @schedule.reserve(not_before: 30) }
    assert_equal Time.current + 120.seconds, @schedule.horizon

    travel 121.seconds
    assert_nil @schedule.horizon
  end
end
