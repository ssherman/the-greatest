require "test_helper"

module Workflows
  class OutcomeTest < ActiveSupport::TestCase
    test "wait carries its time, release flag and result" do
      outcome = Workflows::Outcome.wait(Time.zone.parse("2026-10-20 12:00"), release: true, result: {"in_line" => true})
      assert_equal [:wait, true, {"in_line" => true}], [outcome.kind, outcome.release, outcome.result]
      assert_equal Time.zone.parse("2026-10-20 12:00"), outcome.run_after
    end

    test "wait without a time is refused: the sweep only wakes a step whose run_after has passed" do
      assert_raises(ArgumentError) { Workflows::Outcome.wait(nil) }
    end

    test "wait does not release by default" do
      outcome = Workflows::Outcome.wait(1.minute.from_now)
      assert_equal [false, {}], [outcome.release, outcome.result]
    end

    test "succeeded carries its outcome and result" do
      outcome = Workflows::Outcome.succeeded("matched", {"qid" => "Q1"})
      assert_equal [:succeeded, "matched", {"qid" => "Q1"}], [outcome.kind, outcome.outcome, outcome.result]
    end

    test "succeeded defaults to an empty result" do
      assert_equal({}, Workflows::Outcome.succeeded("done").result)
    end

    test "skipped carries its outcome and no result" do
      outcome = Workflows::Outcome.skipped("no_isbn")
      assert_equal [:skipped, "no_isbn", {}], [outcome.kind, outcome.outcome, outcome.result]
    end
  end
end
