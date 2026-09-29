# frozen_string_literal: true

require "test_helper"

class Viaf::ClientTest < ActiveSupport::TestCase
  RATE = {limit: 1003, remaining: 900, remaining_day: 900}.freeze

  def setup
    @base = mock("base_client")
    @base.stubs(:last_rate_limit).returns(RATE)
    @gate = mock("gate")
    @gate.stubs(:wait_seconds).returns(nil)
    @gate.stubs(:observe)
    @client = Viaf::Client.new(base_client: @base, gate: @gate, cache: ActiveSupport::Cache::MemoryStore.new)
  end

  def suggest_response
    {data: {"result" => [{"viafid" => "1", "term" => "Stacy Willingham", "displayForm" => "Stacy Willingham", "nametype" => "personal"}]}}
  end

  test "the default transport paces in immediate mode, so no worker thread sleeps" do
    Viaf::RateLimiter.expects(:new).with(mode: :immediate).returns(stub(wait!: nil))

    Viaf::Client.new(gate: @gate)
  end

  test "asks nothing of VIAF while the gate is closed, and carries the wait" do
    @gate.stubs(:wait_seconds).returns(600)
    @base.expects(:get).never

    error = assert_raises(Viaf::Exceptions::RateLimited) { @client.get("viaf/1") }

    assert_equal 600, error.retry_after
  end

  test "reads the budget headers after every answer, a 404 included" do
    @base.expects(:get).raises(Viaf::Exceptions::NotFoundError.new("Not found", 404))
    @gate.expects(:observe).with(RATE)

    assert_raises(Viaf::Exceptions::NotFoundError) { @client.get("viaf/1") }
  end

  test "a busy pace becomes RateLimited with its wait, rounded up" do
    @base.stubs(:get).raises(::DistributedRateLimiter::RateLimitExceeded.new("busy", key: "viaf:api", retry_after: 12.2))

    error = assert_raises(Viaf::Exceptions::RateLimited) { @client.get("viaf/1") }

    assert_equal 13, error.retry_after
  end

  test "a Cloudflare block closes the gate and becomes RateLimited for the whole pause" do
    @base.stubs(:get).raises(Viaf::Exceptions::BlockedError.new("blocked", 403))
    @gate.expects(:blocked!).returns(7200)

    error = assert_raises(Viaf::Exceptions::RateLimited) { @client.get("viaf/1") }

    assert_equal 7200, error.retry_after
  end

  test "RateLimited is not a VIAF error, so a rescue of Error never swallows it" do
    assert_not_kind_of Viaf::Exceptions::Error, Viaf::Exceptions::RateLimited.new("wait", retry_after: 1)
  end

  test "an AutoSuggest answer is cached for a day, so a rescheduled run asks once" do
    @base.expects(:get).with("viaf/AutoSuggest", {query: "Stacy Willingham"}).twice.returns(suggest_response)

    2.times { assert_equal ["1"], @client.suggest("Stacy Willingham").map(&:viaf_id) }
    travel 1.day + 1.second
    @client.suggest("Stacy Willingham")
  end

  test "a stored cluster is read while VIAF is paused" do
    ExternalRecord.create!(source: :viaf, source_id: "1", payload: {"viaf_id" => "1", "name_type" => "Personal"},
      schema_version: Viaf::Distiller::SCHEMA_VERSION, fetched_at: Time.current)
    @gate.stubs(:wait_seconds).returns(600)
    @base.expects(:get).never

    assert_equal "1", @client.cluster("1").viaf_id
  end

  test "a cluster not held is fetched through the gate" do
    @gate.stubs(:wait_seconds).returns(600)

    assert_raises(Viaf::Exceptions::RateLimited) { @client.cluster("2") }
  end
end
