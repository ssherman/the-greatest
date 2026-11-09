# frozen_string_literal: true

require "test_helper"

class Books::CategorizeBackfillJobTest < ActiveSupport::TestCase
  test "runs the backfill and logs what it planned" do
    done_at = Time.utc(2026, 11, 6, 12)
    ::Services::Books::Categorize::Backfill.expects(:call).with(scope: "origin_only", limit: 5, label: "v1", book_ids: [1])
      .returns(::Services::Books::Categorize::Backfill::Result.new(success?: true, errors: [], data: {planned: 3, reused: 1, done_at: done_at}))
    Rails.logger.expects(:info).with { it.start_with?("Categorize backfill v1: planned 3 (reused 1), evidence done by") }

    Books::CategorizeBackfillJob.new.perform("origin_only", 5, "v1", [1])
  end

  test "logs a refusal without raising" do
    ::Services::Books::Categorize::Backfill.expects(:call)
      .returns(::Services::Books::Categorize::Backfill::Result.new(success?: false, data: nil, errors: ["scope x arrives with stage 3 (categories); use origin_only"]))
    Rails.logger.expects(:warn).with { it.include?("arrives with stage 3") }

    Books::CategorizeBackfillJob.new.perform("x", nil, "v1")
  end

  test "is a low queue job that does not retry" do
    assert_equal "low", Books::CategorizeBackfillJob.get_sidekiq_options["queue"].to_s
    assert_equal false, Books::CategorizeBackfillJob.get_sidekiq_options["retry"]
  end
end
