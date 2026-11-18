# frozen_string_literal: true

require "test_helper"

class Books::PublisherIntake::DailyJobTest < ActiveSupport::TestCase
  include PublisherIntakeFetchHelper

  setup do
    freeze_time
    setup_intake_fetching
    PublisherIntakeFetchHelper::TestStrategy.discovery_requests_value =
      [Books::PublisherIntake::Request.page("https://x.test/a")]
    Books::PublisherIntake::DiscoveryRequestJob.stubs(:perform_async)
  end

  teardown { teardown_intake_fetching }

  def runs(source = SOURCE) = Books::PublisherIntakeRun.where(source: source)

  def run_row(status:, started_at:, finished_at: nil, source: SOURCE)
    Books::PublisherIntakeRun.create!(source: source, kind: :weekly, status: status, baseline: false,
      started_at: started_at, finished_at: finished_at, counts: {})
  end

  test "does nothing when no source is enabled" do
    Books::PublisherIntake.settings.enabled_sources = []
    Books::PublisherIntake.expects(:gate_for).never
    Services::Books::PublisherIntake::QueueRereads.expects(:call).never

    assert_no_queries { Books::PublisherIntake::DailyJob.new.perform }
  end

  test "starts a run for an enabled source with no finished run in the last 7 days" do
    run_row(status: :finished, started_at: 9.days.ago, finished_at: 8.days.ago)

    assert_difference -> { runs.count }, 1 do
      Books::PublisherIntake::DailyJob.new.perform
    end
    assert_predicate runs.order(:id).last, :status_running?
  end

  test "starts a run when the source has never run" do
    assert_difference -> { runs.count }, 1 do
      Books::PublisherIntake::DailyJob.new.perform
    end
  end

  test "does not start a run while one is running, or within 7 days of a finished one" do
    running = run_row(status: :running, started_at: 1.day.ago)
    assert_no_difference -> { runs.count } do
      Books::PublisherIntake::DailyJob.new.perform
    end

    running.update!(status: :finished, finished_at: 2.days.ago)
    assert_no_difference -> { runs.count } do
      Books::PublisherIntake::DailyJob.new.perform
    end
  end

  test "the cadence counts calendar days from the day a run started, not from when it finished" do
    {"7 days ago plus 5 seconds" => 7.days.ago + 5.seconds, "7 days ago minus 5 seconds" => 7.days.ago - 5.seconds}.each do |label, started|
      Books::PublisherIntakeRun.where(source: SOURCE).delete_all
      run_row(status: :finished, started_at: started, finished_at: started + 6.hours)

      assert_difference -> { runs.count }, 1 do
        Books::PublisherIntake::DailyJob.new.perform
      end
      assert_predicate runs.order(:id).last, :status_running?, label
    end
  end

  test "a run that started 6 days ago keeps the source from running again" do
    run_row(status: :finished, started_at: 6.days.ago, finished_at: 6.days.ago + 1.hour)

    assert_no_difference -> { runs.count } do
      Books::PublisherIntake::DailyJob.new.perform
    end
  end

  test "a failed run yesterday does not stop today's run" do
    run_row(status: :failed, started_at: 1.day.ago, finished_at: 1.day.ago)

    assert_difference -> { runs.count }, 1 do
      Books::PublisherIntake::DailyJob.new.perform
    end
  end

  test "fails a run that has been running for more than 3 days" do
    stuck = run_row(status: :running, started_at: 4.days.ago)

    assert_difference -> { runs.count }, 1 do
      Books::PublisherIntake::DailyJob.new.perform
    end
    stuck.reload
    assert_predicate stuck, :status_failed?
    assert_equal "no progress for 3 days", stuck.error
    assert_equal Time.current, stuck.finished_at
  end

  test "leaves a run that has been running for less than 3 days" do
    fresh = run_row(status: :running, started_at: 2.days.ago)

    Books::PublisherIntake::DailyJob.new.perform

    assert_predicate fresh.reload, :status_running?
  end

  test "re-reads are queued before runs start" do
    title = Books::PublisherTitle.create!(source: SOURCE, title: "T", status: :held, hold_reason: :placeholder)
    listing = Books::PublisherListing.create!(source: SOURCE, url: "https://x.test/r", external_key: "k", state: :read,
      read_at: 40.days.ago, publisher_title: title, first_seen_at: 50.days.ago, last_seen_at: 1.day.ago)

    Books::PublisherIntake::DailyJob.new.perform

    assert_predicate listing.reload, :state_pending?
  end

  test "ignores rows of a source that is no longer registered or enabled" do
    title = Books::PublisherTitle.create!(source: "removed_source", title: "T", status: :held, hold_reason: :placeholder)
    listing = Books::PublisherListing.create!(source: "removed_source", url: "https://x.test/g", external_key: "k",
      state: :read, read_at: 40.days.ago, publisher_title: title, first_seen_at: 50.days.ago, last_seen_at: 1.day.ago)
    young = run_row(status: :running, started_at: 1.day.ago, source: "removed_source")
    old = run_row(status: :running, started_at: 5.days.ago, source: "removed_source_2")

    Books::PublisherIntake::DailyJob.new.perform

    assert_predicate listing.reload, :state_read?
    assert_predicate young.reload, :status_running?
    assert_predicate old.reload, :status_failed?
    assert_equal 1, runs("removed_source").count
  end
end
