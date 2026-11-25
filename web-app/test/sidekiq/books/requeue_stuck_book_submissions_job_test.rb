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
    past_attempt = stale(next_attempt_at: 31.minutes.ago)
    Books::ProcessBookSubmissionJob.expects(:perform_async).with(queued.id)
    Books::ProcessBookSubmissionJob.expects(:perform_async).with(looking_up.id)
    Books::ProcessBookSubmissionJob.expects(:perform_async).with(past_attempt.id)

    Books::RequeueStuckBookSubmissionsJob.new.perform
  end

  test "a row whose attempt is due now, or came due within 30 minutes, is held by its own job and is not requeued" do
    due_now = stale(next_attempt_at: Time.current)
    just_due = stale(next_attempt_at: 29.minutes.ago)
    [due_now, just_due].each { |row| Books::ProcessBookSubmissionJob.expects(:perform_async).with(row.id).never }

    Books::RequeueStuckBookSubmissionsJob.new.perform
  end

  test "a requeue is counted, and a row still stuck after three requeues is failed as a lost job" do
    row = stale
    flagged = finder_match(subject: row, needs_review: true).decision
    Books::ProcessBookSubmissionJob.expects(:perform_async).with(row.id).times(3)

    3.times do
      Books::RequeueStuckBookSubmissionsJob.new.perform
      row.reload.update_columns(updated_at: 31.minutes.ago)
    end
    assert_equal [3, "queued"], [row.sweeps, row.status]

    Books::RequeueStuckBookSubmissionsJob.new.perform

    row.reload
    assert_equal ["failed", "lost job", 3], [row.status, row.error, row.sweeps]
    assert_not flagged.reload.needs_review?
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
