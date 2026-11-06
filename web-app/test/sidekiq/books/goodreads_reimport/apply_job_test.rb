require "test_helper"

class Books::GoodreadsReimport::ApplyJobTest < ActiveSupport::TestCase
  def result(**data)
    Services::Books::GoodreadsReimport::Apply::Result.new(success?: true, data: {applied: 0, noop: 0, failed: 0, cursor: nil}.merge(data), errors: [])
  end

  setup do
    @config = Rails.configuration.x.goodreads_reimport
    @was = @config.enabled
    @config.enabled = true
  end

  teardown { @config.enabled = @was }

  # A session of its own: the test's transaction pins the pool's connection, which would share the lock.
  def other_connection
    config = ActiveRecord::Base.connection_db_config.configuration_hash
    PG.connect(dbname: config[:database], host: config[:host], port: config[:port], user: config[:username], password: config[:password])
  end

  test "does nothing while the gate is off" do
    @config.enabled = false
    Services::Books::GoodreadsReimport::Apply.expects(:call).never

    Books::GoodreadsReimport::ApplyJob.new.perform
  end

  test "queues itself again with the cursor, and passes the cursor it was given on" do
    cursor = {"kind" => "reimport_row", "id" => 9}
    Services::Books::GoodreadsReimport::Apply.expects(:call).with(after: nil).returns(result(applied: 500, cursor: cursor))

    Sidekiq::Testing.fake! do
      Books::GoodreadsReimport::ApplyJob.new.perform
      assert_equal [[cursor]], Books::GoodreadsReimport::ApplyJob.jobs.map { |job| job["args"] }
    ensure
      Books::GoodreadsReimport::ApplyJob.clear
    end
  end

  test "stops when the walk reached the end" do
    Services::Books::GoodreadsReimport::Apply.expects(:call).with(after: {"kind" => "reimport_row", "id" => 9}).returns(result(applied: 2))

    Sidekiq::Testing.fake! do
      Books::GoodreadsReimport::ApplyJob.new.perform({"kind" => "reimport_row", "id" => 9})
      assert_empty Books::GoodreadsReimport::ApplyJob.jobs
    end
  end

  test "a second copy exits at once while the first holds the lock" do
    other = other_connection
    begin
      assert_equal "t", other.exec("SELECT pg_try_advisory_lock(#{Books::GoodreadsReimport::ApplyJob::LOCK_KEY})").getvalue(0, 0)
      Services::Books::GoodreadsReimport::Apply.expects(:call).never

      Sidekiq::Testing.fake! do
        Books::GoodreadsReimport::ApplyJob.new.perform
        assert_empty Books::GoodreadsReimport::ApplyJob.jobs
      end
    ensure
      other.exec("SELECT pg_advisory_unlock(#{Books::GoodreadsReimport::ApplyJob::LOCK_KEY})")
      other.close
    end
  end

  test "releases the lock when the run raises" do
    Services::Books::GoodreadsReimport::Apply.expects(:call).raises(RuntimeError, "boom")
    assert_raises(RuntimeError) { Books::GoodreadsReimport::ApplyJob.new.perform }

    other = other_connection
    begin
      assert_equal "t", other.exec("SELECT pg_try_advisory_lock(#{Books::GoodreadsReimport::ApplyJob::LOCK_KEY})").getvalue(0, 0)
    ensure
      other.exec("SELECT pg_advisory_unlock(#{Books::GoodreadsReimport::ApplyJob::LOCK_KEY})")
      other.close
    end
  end
end
