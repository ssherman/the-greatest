# frozen_string_literal: true

require "test_helper"

class Books::PublisherIntake::ReadListingJobTest < ActiveSupport::TestCase
  include PublisherIntakeFetchHelper

  Job = Books::PublisherIntake::ReadListingJob

  setup do
    freeze_time
    setup_intake_fetching
    @listing = new_pending_listing
    # Inline Sidekiq would run a rescheduled job again at once, forever.
    Job.stubs(:perform_in)
  end

  teardown { teardown_intake_fetching }

  test "runs on the publisher_fetch queue with two retries" do
    options = Job.get_sidekiq_options

    assert_equal ["publisher_fetch", 2], [options["queue"].to_s, options["retry"]]
  end

  test "ReadListingJob reschedules itself with due true on a wait and never sleeps" do
    @gate.reserve
    @client.expects(:fetch).never
    Job.expects(:perform_in).with(10, @listing.id, true)

    Job.new.perform(@listing.id)
  end

  test "a fetch ends the job without rescheduling" do
    @client.stubs(:fetch).returns(page_response)
    PublisherIntakeFetchHelper::TestStrategy.listing_reading =
      Books::PublisherIntake::Reading.new(outcome: :unparseable, facts: nil, sibling_keys: [])
    Job.expects(:perform_in).never

    Job.new.perform(@listing.id, true)

    assert_equal "unparseable", @listing.reload.last_attempt_outcome
  end

  test "a listing that no longer exists ends the job" do
    Job.expects(:perform_in).never

    Job.new.perform(0)
  end
end
