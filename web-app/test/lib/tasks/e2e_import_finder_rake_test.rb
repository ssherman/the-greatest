# frozen_string_literal: true

require "test_helper"
require "rake"

class E2eImportFinderRakeTest < ActiveSupport::TestCase
  MARKER = "E2E import finder audit seed"

  setup do
    unless Rake::Task.task_defined?("e2e:import_finder_seed")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/e2e.rake").to_s }
    end
    @seed = Rake::Task["e2e:import_finder_seed"]
    @cleanup = Rake::Task["e2e:import_finder_cleanup"]
    @seed.reenable
    @cleanup.reenable
    @previous = ENV.slice("E2E_BOOK_A", "E2E_BOOK_B")
    ENV["E2E_BOOK_A"] = "crime-and-punishment"
    ENV["E2E_BOOK_B"] = "war-and-peace"
    @a = books_books(:crime_and_punishment)
    @b = books_books(:war_and_peace)
  end

  teardown do
    ENV.delete("E2E_BOOK_A")
    ENV.delete("E2E_BOOK_B")
    ENV.update(@previous)
  end

  def seeded_pair
    x, y = [@a.id, @b.id].minmax
    DuplicateCandidate.find_by(item_type: "Books::Book", item_a_id: x, item_b_id: y)
  end

  test "seed creates one unmatched needs-review decision with the created record and one local candidate, one pending pair, and prints their ids" do
    output = nil
    assert_difference("MatchDecision.count", 1) do
      assert_difference("DuplicateCandidate.count", 1) do
        output = capture_io { @seed.invoke }.first
      end
    end

    ids = JSON.parse(output.lines.last)
    decision = MatchDecision.find(ids["decision_id"])
    pair = DuplicateCandidate.find(ids["pair_id"])

    assert decision.unmatched?
    assert decision.needs_review?
    assert_equal @a, decision.record
    assert_equal MARKER, decision.reason
    assert_equal [@b.id], decision.candidates.map { |candidate| candidate["record_id"] }
    assert_equal @a.title, decision.query["title"]

    assert pair.pending?
    assert pair.raised_by_bulk_verify?
    assert_equal MARKER, pair.evidence["reason"]
    assert_equal decision, pair.match_decision
    assert_equal seeded_pair, pair
  end

  test "seed is idempotent and resets a reviewed decision and a dismissed pair" do
    capture_io { @seed.invoke }
    decision = MatchDecision.find_by!(reason: MARKER)
    decision.review!(by: users(:admin_user), note: "done")
    decision.update_column(:created_at, 3.days.ago)
    seeded_pair.update!(status: :not_duplicate, resolved_at: Time.current, resolution_note: "no")
    @seed.reenable

    assert_no_difference(["MatchDecision.count", "DuplicateCandidate.count"]) do
      capture_io { @seed.invoke }
    end

    assert_nil decision.reload.reviewed_at
    assert seeded_pair.pending?
    assert_nil seeded_pair.resolution_note
    assert_operator decision.reload.created_at, :>, 1.minute.ago
  end

  test "seed refuses to clobber a real pair between the two books" do
    x, y = [@a.id, @b.id].minmax
    DuplicateCandidate.create!(item_type: "Books::Book", item_a_id: x, item_b_id: y, source: :ai, status: :pending, evidence: {"reason" => "a real one"})

    assert_output(nil, /already exists/) do
      assert_raises(SystemExit) { @seed.invoke }
    end
    assert_nil MatchDecision.find_by(reason: MARKER)
  end

  test "cleanup removes only what the seed created" do
    capture_io { @seed.invoke }
    untouched_decision = match_decisions(:low_confidence_book_match)
    untouched_pair = duplicate_candidates(:books_pending_pair)

    assert_difference("MatchDecision.count", -1) do
      assert_difference("DuplicateCandidate.count", -1) do
        assert_output(/removed 1 pair\(s\) and 1 decision\(s\)/) { @cleanup.invoke }
      end
    end
    assert MatchDecision.exists?(untouched_decision.id)
    assert DuplicateCandidate.exists?(untouched_pair.id)
    assert_nil MatchDecision.find_by(reason: MARKER)
  end
end
