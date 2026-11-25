require "test_helper"

class Books::RequeueStuckBookSubmissionsJobTest < ActiveSupport::TestCase
  include BookSubmissionHelper

  setup do
    freeze_time
    Books::ProcessBookSubmissionJob.stubs(:perform_async)
  end

  def stale(**attributes)
    book_submission(**attributes).tap { |submission| submission.update_columns(updated_at: 31.minutes.ago) }
  end

  test "runs on the low queue" do
    assert_equal "low", Books::RequeueStuckBookSubmissionsJob.get_sidekiq_options["queue"].to_s
  end

  test "is scheduled every ten minutes" do
    entry = YAML.load_file(Rails.root.join("config/schedule.yml")).values.find { |job| job["class"] == "Books::RequeueStuckBookSubmissionsJob" }

    assert_equal "*/10 * * * *", entry["cron"]
  end

  test "queued and looking up rows idle for over 30 minutes with no future attempt are requeued" do
    queued = stale
    looking_up = stale(status: :looking_up)
    past_attempt = stale(next_attempt_at: 5.minutes.ago)
    Books::ProcessBookSubmissionJob.expects(:perform_async).with(queued.id)
    Books::ProcessBookSubmissionJob.expects(:perform_async).with(looking_up.id)
    Books::ProcessBookSubmissionJob.expects(:perform_async).with(past_attempt.id)

    Books::RequeueStuckBookSubmissionsJob.new.perform
  end

  test "a row waiting on a future attempt is not requeued" do
    waiting = stale(next_attempt_at: 5.minutes.from_now)
    Books::ProcessBookSubmissionJob.expects(:perform_async).with(waiting.id).never

    Books::RequeueStuckBookSubmissionsJob.new.perform
  end

  test "a recently touched row is not requeued" do
    fresh = book_submission.tap { |submission| submission.update_columns(updated_at: 29.minutes.ago) }
    Books::ProcessBookSubmissionJob.expects(:perform_async).with(fresh.id).never

    Books::RequeueStuckBookSubmissionsJob.new.perform
  end

  test "added, failed, cancelled and needs_details rows are not requeued" do
    %i[added failed cancelled needs_details].each do |status|
      Books::ProcessBookSubmissionJob.expects(:perform_async).with(stale(status: status).id).never
    end

    Books::RequeueStuckBookSubmissionsJob.new.perform
  end

  test "a requeued row is touched so the next sweep leaves it to its job" do
    submission = stale

    Books::RequeueStuckBookSubmissionsJob.new.perform

    assert_equal Time.current, submission.reload.updated_at
  end
end
