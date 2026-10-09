# frozen_string_literal: true

require "test_helper"

class Books::OpenLibraryBackfillJobTest < ActiveSupport::TestCase
  test "runs the backfill with its limit, run id and mode, on the low queue without retries" do
    ::Services::Books::OlBackfill::Run.expects(:call).with(limit: 100, run_id: "run-1", retry_unsure: true)
      .returns(::Services::Books::OlBackfill::Run::Result.new(success?: true, data: {processed: 100, stopped: false, error: nil}, errors: []))

    Books::OpenLibraryBackfillJob.new.perform(100, "run-1", true)

    assert_equal ["low", false], Books::OpenLibraryBackfillJob.get_sidekiq_options.values_at("queue", "retry").map { |value| value.is_a?(Symbol) ? value.to_s : value }
  end
end
