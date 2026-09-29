# frozen_string_literal: true

require "test_helper"

class Viaf::GateTest < ActiveSupport::TestCase
  # CI has no Redis. FakeRedis implements the hash commands the gate uses
  # and models expiry against Time.current, so travel exercises it.
  def setup
    @gate = Viaf::Gate.new(redis: Books::OpenLibrary::FakeRedis.new)
  end

  def budget(left) = {limit: 1003, remaining: left, remaining_day: left}

  test "is open until something closes it" do
    assert_nil @gate.wait_seconds
  end

  test "a Cloudflare block pauses every call for an hour" do
    assert_equal 3600, @gate.blocked!
    assert_in_delta 3600, @gate.wait_seconds, 1

    travel 3601.seconds
    assert_nil @gate.wait_seconds
  end

  test "each repeat block doubles the pause, up to a day" do
    pauses = 7.times.map do
      seconds = @gate.blocked!
      travel((seconds + 1).seconds)
      seconds
    end

    assert_equal [3600, 7200, 14_400, 28_800, 57_600, 86_400, 86_400], pauses
  end

  test "a real VIAF answer resets the doubling" do
    @gate.blocked!
    travel 3601.seconds
    @gate.observe(budget(900))

    assert_equal 3600, @gate.blocked!
  end

  test "an answer without budget headers, as Cloudflare's page has none, resets nothing" do
    @gate.blocked!
    travel 3601.seconds
    @gate.observe({limit: nil, remaining: nil, remaining_day: nil})
    @gate.observe(nil)

    assert_equal 7200, @gate.blocked!
  end

  test "fewer than 50 requests left for the day pauses an hour, reading the smaller of the two counts" do
    @gate.observe({limit: 1003, remaining: 900, remaining_day: 49})

    assert_in_delta 3600, @gate.wait_seconds, 1
  end

  test "50 or more left leaves it open" do
    @gate.observe(budget(50))

    assert_nil @gate.wait_seconds
  end

  test "a low budget never shortens a longer block" do
    @gate.blocked!
    @gate.blocked!
    @gate.observe(budget(10))

    assert_in_delta 7200, @gate.wait_seconds, 2
  end
end
