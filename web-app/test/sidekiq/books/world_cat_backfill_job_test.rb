require "test_helper"

class Books::WorldCatBackfillJobTest < ActiveSupport::TestCase
  test "runs the backfill with its limit and run id on the low queue without retries" do
    result = Services::Books::WorldCat::Backfill::Result.new(success?: true, data: {processed: 10, matched: 8, genres_linked: 9, subjects_linked: 2, type_conflicts: 0, subjects_unresolved: {}, stopped: false, error: nil}, errors: [])
    Services::Books::WorldCat::Backfill.expects(:call).with(limit: 10, run_id: "run-1").returns(result)

    Books::WorldCatBackfillJob.new.perform(10, "run-1")

    options = Books::WorldCatBackfillJob.get_sidekiq_options
    assert_equal ["low", false], [options["queue"].to_s, options["retry"]]
  end
end
