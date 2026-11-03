require "test_helper"

class Books::GoodreadsReimport::DecideGuessesJobTest < ActiveSupport::TestCase
  setup do
    @config = Rails.configuration.x.goodreads_reimport
    @was = @config.enabled
    @approved = Books::RepairVerdict.create!(kind: :reimport_mixed, subject_key: "reimport:book:1", decided_by: :rule, status: :approved, payload: {})
    Books::RepairVerdict.create!(kind: :reimport_mixed, subject_key: "reimport:book:2", decided_by: :rule, status: :proposed, payload: {})
    Books::RepairVerdict.create!(kind: :reimport_mixed, subject_key: "reimport:book:3", decided_by: :rule, status: :approved, superseded_at: Time.current, payload: {})
  end

  teardown { @config.enabled = @was }

  test "does nothing while the gate is off" do
    @config.enabled = false
    Services::Books::GoodreadsReimport::DecideGuesses.expects(:call).never

    Books::GoodreadsReimport::DecideGuessesJob.new.perform([@approved.id])
  end

  test "decides each verdict and survives one raising" do
    @config.enabled = true
    second = Books::RepairVerdict.create!(kind: :reimport_mixed, subject_key: "reimport:book:4", decided_by: :rule, status: :approved, payload: {})
    done = Services::Books::GoodreadsReimport::DecideGuesses::Result.new(success?: true, data: {outcome: :decided}, errors: [])
    Services::Books::GoodreadsReimport::DecideGuesses.expects(:call).with(mixed_verdict: @approved).returns(done)
    Services::Books::GoodreadsReimport::DecideGuesses.expects(:call).with(mixed_verdict: second).raises(RuntimeError, "boom")
    Rails.logger.stubs(:error)
    Rails.logger.expects(:info).with { |line| line.include?("decided 1") && line.include?("errors 1") }

    Books::GoodreadsReimport::DecideGuessesJob.new.perform([@approved.id, second.id])
  end

  test "enqueue queues only approved current mixed verdicts" do
    batches = []
    Books::GoodreadsReimport::DecideGuessesJob.stubs(:perform_async).with { |batch| batches << batch }

    assert_equal 1, Books::GoodreadsReimport::DecideGuessesJob.enqueue
    assert_equal [[@approved.id]], batches
  end
end
