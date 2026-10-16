# frozen_string_literal: true

require "test_helper"

class Books::VerificationJobTest < ActiveSupport::TestCase
  test "runs the backfill with its limit, run id and flags, on the low queue without retries" do
    ::Services::Books::Verification::Run.expects(:call).with(limit: 100, run_id: "run-1", flags: %w[post_import])
      .returns(::Services::Books::Verification::Run::Result.new(success?: true, data: {processed: 100, stopped: false, error: nil}, errors: []))

    Books::VerificationJob.new.perform(100, "run-1", %w[post_import])

    assert_equal ["low", false], Books::VerificationJob.get_sidekiq_options.values_at("queue", "retry").map { |value| value.is_a?(Symbol) ? value.to_s : value }
  end
end
