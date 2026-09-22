require "test_helper"

class MatchDecisionTest < ActiveSupport::TestCase
  def setup
    @book = books_books(:war_and_peace)
  end

  test "is valid with a finder, outcome, confidence and decided_by and no record" do
    decision = MatchDecision.new(
      finder: "DataImporters::Books::Book::Finder",
      outcome: :unmatched, confidence: :high, decided_by: :rule, reason: "no candidates"
    )

    assert decision.valid?
  end

  test "requires a finder" do
    decision = MatchDecision.new(outcome: :matched, confidence: :certain, decided_by: :identifier)

    assert_not decision.valid?
    assert_includes decision.errors[:finder], "can't be blank"
  end

  test "records a polymorphic record and subject" do
    item = list_items(:music_albums_item)
    decision = MatchDecision.create!(
      finder: "DataImporters::Books::Book::Finder", record: @book, subject: item,
      outcome: :matched, confidence: :certain, decided_by: :identifier
    )

    assert_equal @book, decision.reload.record
    assert_equal item, decision.subject
  end

  test "decided_by predicates are prefixed" do
    decision = MatchDecision.new(finder: "F", outcome: :matched, confidence: :high, decided_by: :ai)

    assert decision.decided_by_ai?
    assert_not decision.decided_by_rule?
  end

  test "needing_review returns only unreviewed rows flagged for review, newest first" do
    old = MatchDecision.create!(finder: "F", outcome: :unmatched, confidence: :low, decided_by: :ai, needs_review: true, created_at: 2.days.ago)
    newer = MatchDecision.create!(finder: "F", outcome: :unmatched, confidence: :low, decided_by: :ai, needs_review: true, created_at: 1.day.ago)
    MatchDecision.create!(finder: "F", outcome: :matched, confidence: :high, decided_by: :rule, needs_review: false)
    reviewed = MatchDecision.create!(finder: "F", outcome: :unmatched, confidence: :low, decided_by: :ai, needs_review: true)
    reviewed.review!(by: users(:admin_user), note: "fine")

    assert_equal [newer, old], MatchDecision.for_finder("F").needing_review.newest_first.to_a
  end

  test "review! stamps who, when and the note" do
    decision = MatchDecision.create!(finder: "F", outcome: :unmatched, confidence: :low, decided_by: :fallback, needs_review: true)

    decision.review!(by: users(:admin_user), note: "checked")

    decision.reload
    assert_equal users(:admin_user), decision.reviewed_by
    assert_not_nil decision.reviewed_at
    assert_equal "checked", decision.review_note
  end

  test "destroying the record nullifies the decision's record link" do
    game = games_games(:half_life_2)
    RankedItem.where(item: game).destroy_all
    decision = MatchDecision.create!(finder: "F", record: game, outcome: :matched, confidence: :certain, decided_by: :identifier)

    game.destroy!

    assert_nil decision.reload.record_id
  end

  test "destroying the reviewing user nullifies reviewed_by" do
    user = User.create!(email: "reviewer-#{SecureRandom.hex(4)}@example.com", display_name: "R", name: "R")
    decision = MatchDecision.create!(finder: "F", outcome: :unmatched, confidence: :low, decided_by: :ai, needs_review: true)
    decision.review!(by: user)

    user.destroy!

    assert_nil decision.reload.reviewed_by_id
  end
end
