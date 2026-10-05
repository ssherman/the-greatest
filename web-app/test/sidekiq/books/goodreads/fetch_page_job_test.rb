# frozen_string_literal: true

require "test_helper"

class Books::Goodreads::FetchPageJobTest < ActiveSupport::TestCase
  include GoodreadsImportHelper

  FETCH = Services::Books::GoodreadsPages::FetchPage

  # CI has no Redis: the gate runs on FakeRedis, with the clock frozen.
  # Sidekiq runs inline in tests, so the jobs this one queues are stubbed.
  setup do
    freeze_time
    config = ActiveSupport::OrderedOptions.new.merge(fetch_interval: 15, daily_fetch_cap: 1_500, block_cooldown: 6.hours.to_i)
    @gate = Books::Goodreads::FetchGate.new(redis: Books::OpenLibrary::FakeRedis.new, config: config)
    Books::Goodreads::FetchGate.stubs(:new).returns(@gate)
    Books::Goodreads::SettleEditionsJob.stubs(:perform_async)
    @edition = goodreads_edition(verification: :pending)
    @id = @edition.goodreads_book_id
  end

  def fetched(outcome)
    FETCH::Result.new(success?: true, data: {outcome: outcome, page: nil}, errors: [])
  end

  test "runs on the goodreads_fetch queue with three retries" do
    options = Books::Goodreads::FetchPageJob.get_sidekiq_options

    assert_equal ["goodreads_fetch", 3], [options["queue"].to_s, options["retry"]]
  end

  test "fetches at once when the line is free, then settles the id's editions" do
    FETCH.expects(:call).with(goodreads_book_id: @id).returns(fetched(:found))
    Books::Goodreads::SettleEditionsJob.expects(:perform_async).with(@id)

    Books::Goodreads::FetchPageJob.new.perform(@id)
  end

  test "a busy line reschedules the job for its turn instead of waiting in a thread" do
    @gate.reserve
    FETCH.expects(:call).never
    Books::Goodreads::FetchPageJob.expects(:perform_in).with(15, @id, true, 1)

    Books::Goodreads::FetchPageJob.new.perform(@id)
  end

  test "a job on its turn fetches without reserving another" do
    2.times { @gate.reserve }
    FETCH.expects(:call).returns(fetched(:found))
    Books::Goodreads::FetchPageJob.expects(:perform_in).never

    Books::Goodreads::FetchPageJob.new.perform(@id, true)
  end

  test "an id already answered is settled without a fetch" do
    goodreads_page(goodreads_book_id: @id)
    FETCH.expects(:call).never
    Books::Goodreads::SettleEditionsJob.expects(:perform_async).with(@id)

    Books::Goodreads::FetchPageJob.new.perform(@id)
  end

  test "an id nothing waits on is not fetched" do
    @edition.update!(verification: :not_needed)
    FETCH.expects(:call).never
    Books::Goodreads::SettleEditionsJob.expects(:perform_async).never

    Books::Goodreads::FetchPageJob.new.perform(@id)
  end

  test "a spent daily cap or a block settles the editions, unverified, without fetching" do
    FETCH.expects(:call).never
    Books::Goodreads::SettleEditionsJob.expects(:perform_async).with(@id).twice

    @gate.stubs(:reserve).returns(Books::Goodreads::FetchGate::Reservation.new(wait: nil, refusal: :daily_cap))
    Books::Goodreads::FetchPageJob.new.perform(@id)
    @gate.unstub(:reserve)
    @gate.block!
    Books::Goodreads::FetchPageJob.new.perform(@id)
  end

  test "a block that began while the job waited for its turn stops it" do
    @gate.block!
    FETCH.expects(:call).never
    Books::Goodreads::SettleEditionsJob.expects(:perform_async).with(@id)

    Books::Goodreads::FetchPageJob.new.perform(@id, true)
  end

  test "a challenge or an unrecognizable page stops all fetching for the cooldown" do
    [:blocked, :unparseable].each do |outcome|
      @gate.stubs(:blocked?).returns(false)
      FETCH.stubs(:call).returns(fetched(outcome))
      @gate.expects(:block!)

      Books::Goodreads::FetchPageJob.new.perform(@id, true)
    end
  end

  test "no answer tries again through the line, then leaves the edition to be created unverified" do
    FETCH.stubs(:call).returns(fetched(:unavailable))
    Books::Goodreads::FetchPageJob.expects(:perform_async).with(@id, false, 2)
    Books::Goodreads::SettleEditionsJob.expects(:perform_async).never

    Books::Goodreads::FetchPageJob.new.perform(@id, true, 1)

    Books::Goodreads::SettleEditionsJob.expects(:perform_async).with(@id)
    Books::Goodreads::FetchPageJob.new.perform(@id, true, 3)
    assert_not @gate.blocked?
  end
end
