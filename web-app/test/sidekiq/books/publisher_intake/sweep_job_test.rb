# frozen_string_literal: true

require "test_helper"

class Books::PublisherIntake::SweepJobTest < ActiveSupport::TestCase
  include PublisherIntakeFetchHelper

  setup do
    freeze_time
    setup_intake_fetching
    @queued = []
    Books::PublisherIntake::ReadListingJob.stubs(:perform_async).with { |id| @queued << id }
    @gate.stubs(:blocked?).returns(false)
    @gate.stubs(:reopens_at).returns(nil)
  end

  teardown { teardown_intake_fetching }

  def pending(first_seen_at:, queued_at: nil, source: SOURCE, **attrs)
    Books::PublisherListing.create!(source: source, url: "https://x.test/#{SecureRandom.hex(4)}", external_key: "k",
      state: :pending, first_seen_at: first_seen_at, last_seen_at: first_seen_at, queued_at: queued_at, **attrs)
  end

  def sweep = Books::PublisherIntake::SweepJob.new.perform

  def with_interval(seconds)
    settings = Books::PublisherIntake.settings
    original = settings.fetch_interval
    settings.fetch_interval = seconds
    yield
  ensure
    settings.fetch_interval = original
  end

  test "does nothing when no source is enabled" do
    pending(first_seen_at: 1.day.ago)
    Books::PublisherIntake.settings.enabled_sources = []
    Books::PublisherIntake.expects(:gate_for).never

    assert_no_queries { sweep }
    assert_empty @queued
  end

  test "queues the oldest pending listings up to the batch size and stamps queued_at" do
    newest = pending(first_seen_at: 1.day.ago)
    oldest = pending(first_seen_at: 3.days.ago)
    middle = pending(first_seen_at: 2.days.ago)

    with_interval(300) { sweep } # batch of 2

    assert_equal [oldest.id, middle.id], @queued
    assert_equal Time.current, oldest.reload.queued_at
    assert_equal Time.current, middle.reload.queued_at
    assert_nil newest.reload.queued_at
  end

  test "ties on first_seen_at go by id" do
    at = 1.day.ago
    a = pending(first_seen_at: at)
    b = pending(first_seen_at: at)

    sweep

    assert_equal [a.id, b.id], @queued
  end

  test "skips listings queued within the hour and unparseable ones attempted within a day" do
    pending(first_seen_at: 5.days.ago, queued_at: 30.minutes.ago)
    pending(first_seen_at: 5.days.ago, last_attempt_outcome: :unparseable, last_attempt_at: 2.hours.ago)
    stale_queue = pending(first_seen_at: 4.days.ago, queued_at: 2.hours.ago)
    old_unparseable = pending(first_seen_at: 3.days.ago, last_attempt_outcome: :unparseable, last_attempt_at: 2.days.ago)
    blocked_before = pending(first_seen_at: 2.days.ago, last_attempt_outcome: :blocked, last_attempt_at: 1.hour.ago)
    never_tried = pending(first_seen_at: 1.day.ago)

    sweep

    assert_equal [stale_queue.id, old_unparseable.id, blocked_before.id, never_tried.id], @queued
  end

  test "skips listings that are not pending or belong to another source" do
    read = pending(first_seen_at: 2.days.ago)
    read.update!(state: :read)
    pending(first_seen_at: 2.days.ago, source: "removed_source")

    sweep

    assert_empty @queued
  end

  test "skips a source whose gate is blocked" do
    pending(first_seen_at: 1.day.ago)
    @gate.stubs(:blocked?).returns(true)

    sweep

    assert_empty @queued
  end

  test "skips a source whose daily cap is spent" do
    pending(first_seen_at: 1.day.ago)
    @gate.stubs(:reopens_at).returns(5.hours.from_now)

    sweep

    assert_empty @queued
  end

  test "the batch size follows the fetch interval" do
    70.times { |i| pending(first_seen_at: (100 - i).minutes.ago) }

    sweep
    assert_equal 60, @queued.size

    @queued.clear
    Books::PublisherListing.update_all(queued_at: nil)
    with_interval(30) { sweep }
    assert_equal 20, @queued.size
  end

  test "an interval of 0 or above 600 still gives a batch of at least one" do
    2.times { pending(first_seen_at: 1.day.ago) }

    with_interval(0) { sweep }
    assert_operator @queued.size, :>=, 1

    @queued.clear
    Books::PublisherListing.update_all(queued_at: nil)
    with_interval(900) { sweep }
    assert_equal 1, @queued.size
  end
end
