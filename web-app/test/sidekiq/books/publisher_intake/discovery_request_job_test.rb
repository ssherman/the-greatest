# frozen_string_literal: true

require "test_helper"

class Books::PublisherIntake::DiscoveryRequestJobTest < ActiveSupport::TestCase
  include PublisherIntakeFetchHelper

  Job = Books::PublisherIntake::DiscoveryRequestJob
  Request = Books::PublisherIntake::Request
  Discovery = Books::PublisherIntake::Discovery

  setup do
    freeze_time
    setup_intake_fetching
    @run = new_running_run
    @request = Request.page("https://x.test/index.xml")
    @client.stubs(:fetch).returns(page_response)
  end

  teardown { teardown_intake_fetching }

  def discovery(requests) = PublisherIntakeFetchHelper::TestStrategy.discovery_value = Discovery.new(outcome: :ok, listings: [], requests: requests)

  def children(count) = Array.new(count) { |i| Request.page("https://x.test/child#{i}.xml") }

  test "runs on the publisher_fetch queue with two retries" do
    options = Job.get_sidekiq_options

    assert_equal ["publisher_fetch", 2], [options["queue"].to_s, options["retry"]]
  end

  test "a wait reschedules the request with due true and never sleeps" do
    @gate.reserve
    Job.expects(:perform_in).with(10, @run.id, @request.to_h, true, 1)

    Job.new.perform(@run.id, @request.to_h)
  end

  test "a refused turn reschedules with due false so the later attempt reserves a fresh turn" do
    @gate.block!
    Job.expects(:perform_in).with(6.hours.to_i, @run.id, @request.to_h, false, 2)

    Job.new.perform(@run.id, @request.to_h, false, 2)
  end

  test "a blocked response reschedules with due false" do
    PublisherIntakeFetchHelper::TestStrategy.discovery_value = Discovery.new(outcome: :blocked, listings: [], requests: [])
    Job.expects(:perform_in).with(6.hours.to_i, @run.id, @request.to_h, false, 1)

    Job.new.perform(@run.id, @request.to_h, true)
  end

  test "a skipped request leaves the run's counts unchanged" do
    Books::PublisherIntake.settings.enabled_sources = []
    Job.expects(:perform_in).never

    Job.new.perform(@run.id, @request.to_h, true)

    assert_equal [1, 1], @run.reload.counts.values_at("requests", "outstanding")
    assert_predicate @run, :status_running?
  end

  test "an unavailable fetch is queued again with the next attempt" do
    @client.stubs(:fetch).raises(PageFetcher::Exceptions::TimeoutError, "slow")
    Job.expects(:perform_async).with(@run.id, @request.to_h, false, 2)

    Job.new.perform(@run.id, @request.to_h, true, 1)
  end

  test "DiscoveryRequestJob enqueues each follow-up and finishes the run when none is outstanding" do
    kids = children(2)
    discovery(kids)
    Sidekiq::Testing.fake! do
      Job.new.perform(@run.id, @request.to_h, true)

      assert_equal kids.map(&:to_h), Job.jobs.map { |j| j["args"][1] }
      assert_equal [@run.id, @run.id], Job.jobs.map { |j| j["args"][0] }
      assert_equal [3, 2], @run.reload.counts.values_at("requests", "outstanding")
      assert_predicate @run, :status_running?

      discovery([])
      Job.jobs.clear
      2.times do
        travel 10.seconds
        Job.new.perform(@run.id, kids.first.to_h, true)
      end
    end

    @run.reload
    assert_equal [3, 0], @run.counts.values_at("requests", "outstanding")
    assert_predicate @run, :status_finished?
    assert_equal Time.current, @run.finished_at
  end

  test "DiscoveryRequestJob keeps the seed flag on follow-ups" do
    discovery(children(1))
    Sidekiq::Testing.fake! do
      Job.new.perform(@run.id, Request.page("https://x.test/s", context: {"seed" => true}).to_h, true)

      assert_equal [true], Job.jobs.map { |j| j["args"][1]["context"]["seed"] }
    end
  end

  test "a follow-up without a seed parent carries no seed flag" do
    discovery(children(1))
    Sidekiq::Testing.fake! do
      Job.new.perform(@run.id, @request.to_h, true)

      assert_equal [nil], Job.jobs.map { |j| j["args"][1]["context"]["seed"] }
    end
  end

  test "a run with requests still outstanding stays running" do
    @run.update!(counts: {"requests" => 2, "outstanding" => 2})
    discovery([])

    Job.new.perform(@run.id, @request.to_h, true)

    assert_predicate @run.reload, :status_running?
    assert_equal 1, @run.counts["outstanding"]
  end

  test "a failed run is left failed" do
    PublisherIntakeFetchHelper::TestStrategy.discovery_value = Discovery.new(outcome: :unparseable, listings: [], requests: [])

    Job.new.perform(@run.id, @request.to_h, true)

    assert_predicate @run.reload, :status_failed?
    assert_equal 1, @run.counts["outstanding"]
  end
end
