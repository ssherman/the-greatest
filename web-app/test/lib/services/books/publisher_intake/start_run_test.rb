# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module PublisherIntake
      class StartRunTest < ActiveSupport::TestCase
        include PublisherIntakeFetchHelper

        Request = ::Books::PublisherIntake::Request
        Strategy = PublisherIntakeFetchHelper::TestStrategy

        setup do
          freeze_time
          setup_intake_fetching
          @source = ::Books::PublisherIntake::Sources.fetch(SOURCE)
          Strategy.discovery_requests_value = [Request.page("https://x.test/a"), Request.file("https://x.test/b.xml")]
          Strategy.seed_requests_value = [Request.page("https://x.test/seed")]
          @enqueued = []
          ::Books::PublisherIntake::DiscoveryRequestJob.stubs(:perform_async).with { |*args| @enqueued << args }
        end

        teardown { teardown_intake_fetching }

        def finished_run(started_at: 10.days.ago)
          ::Books::PublisherIntakeRun.create!(source: SOURCE, kind: :weekly, status: :finished, baseline: false,
            started_at: started_at, finished_at: started_at + 1.hour, counts: {})
        end

        def start = StartRun.call(source: @source)

        test "the first run of a baseline source is a baseline run and includes the seed requests, flagged" do
          Strategy.baseline_value = true

          run = start.data[:run]

          assert run.baseline
          assert_nil Strategy.since_seen
          seeds = @enqueued.map { |_, hash| hash }.select { |h| h["context"]["seed"] }
          assert_equal ["https://x.test/seed"], seeds.map { |h| h["url"] }
          assert_equal 3, @enqueued.size
          assert(@enqueued.all? { |id, _| id == run.id })
        end

        test "a run after a finished run is not baseline, has no seed requests, and passes since" do
          Strategy.baseline_value = true
          previous = finished_run

          run = start.data[:run]

          refute run.baseline
          assert_equal previous.started_at, Strategy.since_seen
          assert_equal 2, @enqueued.size
          refute(@enqueued.any? { |_, hash| hash["context"]["seed"] })
        end

        test "a failed first run is followed by another baseline run with the seed requests" do
          Strategy.baseline_value = true
          ::Books::PublisherIntakeRun.create!(source: SOURCE, kind: :weekly, status: :failed, baseline: true,
            started_at: 2.days.ago, finished_at: 2.days.ago, counts: {})

          run = start.data[:run]

          assert run.baseline
          assert_includes @enqueued.map { |_, hash| hash["url"] }, "https://x.test/seed"
        end

        test "a dated source's first run is not baseline" do
          Strategy.baseline_value = false

          run = start.data[:run]

          refute run.baseline
          assert_includes @enqueued.map { |_, hash| hash["url"] }, "https://x.test/seed"
        end

        test "counts start with requests and outstanding equal to the number of requests" do
          run = start.data[:run].reload

          assert_equal [3, 3], [run.counts["requests"], run.counts["outstanding"]]
          assert_predicate run, :status_running?
          assert_predicate run, :kind_weekly?
          assert_equal Time.current, run.started_at
        end

        test "the run is saved before its jobs are enqueued" do
          saved = []
          ::Books::PublisherIntake::DiscoveryRequestJob.unstub(:perform_async)
          ::Books::PublisherIntake::DiscoveryRequestJob.stubs(:perform_async).with { |run_id, _| saved << ::Books::PublisherIntakeRun.exists?(run_id) }

          start

          assert_equal [true, true, true], saved
        end

        test "a manual run keeps its kind" do
          run = StartRun.call(source: @source, kind: :manual).data[:run]

          assert_predicate run, :kind_manual?
        end

        test "a source with nothing to request finishes at once" do
          Strategy.discovery_requests_value = []
          Strategy.seed_requests_value = []

          run = start.data[:run].reload

          assert_predicate run, :status_finished?
          assert_equal Time.current, run.finished_at
          assert_equal({"requests" => 0, "outstanding" => 0}, run.counts)
          assert_empty @enqueued
        end

        test "a source with a running run is refused, creating and enqueuing nothing" do
          new_running_run

          result = nil
          assert_no_difference -> { ::Books::PublisherIntakeRun.count } do
            result = start
          end

          refute_predicate result, :success?
          assert_equal ["a run is already running for #{SOURCE}"], result.errors
          assert_empty @enqueued
        end

        test "a running run of another source does not refuse" do
          new_running_run(source: "removed_source")

          assert_predicate start, :success?
        end
      end
    end
  end
end
