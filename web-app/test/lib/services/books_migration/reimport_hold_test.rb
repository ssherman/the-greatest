require "test_helper"

class Services::BooksMigration::ReimportHoldTest < ActiveSupport::TestCase
  include BooksLegacySyncHelper

  def hold(pairs, redirects: [], mixed: Set.new)
    Services::BooksMigration::ReimportHold.new(
      pairs: pairs, redirects: Services::BooksMigration::Redirects.new(redirects), mixed_book_ids: mixed
    )
  end

  def verdict(kind, key, payload, status: :approved, applied_at: Time.current, superseded_at: nil)
    Books::RepairVerdict.create!(kind: kind, subject_key: key, decided_by: :rule, status: status, payload: payload, applied_at: applied_at, superseded_at: superseded_at)
  end

  test "holds both books of a move" do
    subject = hold([[7, 10], [7, 20]])

    assert subject.held?(7, 10)
    assert subject.held?(7, 20)
    assert_not subject.held?(8, 10)
    assert_not subject.held?(7, :deleted)
    assert_not subject.held?(7, nil)
  end

  test "follows a later merge" do
    assert hold([[7, 10], [7, 20]], redirects: [["Books::Book", 20, 30]]).held?(7, 30)
  end

  test "follows a merge chain" do
    assert hold([[7, 20]], redirects: [["Books::Book", 20, 30], ["Books::Book", 30, 40]]).held?(7, 40)
  end

  test "does not follow the redirect a deleted mixed book left" do
    subject = hold([[7, 50]], redirects: [["Books::Book", 50, 60]], mixed: Set[50])

    assert subject.held?(7, 50)
    assert_not subject.held?(7, 60)
  end

  test "stops at a deleted book" do
    subject = hold([[7, 20]], redirects: [["Books::Book", 20, nil]])

    assert subject.held?(7, 20)
    assert_equal 1, subject.size
  end

  test "a redirect cycle does not loop" do
    subject = hold([[7, 20]], redirects: [["Books::Book", 20, 30], ["Books::Book", 30, 20]])

    assert_equal 2, subject.size
  end

  test "load reads changed row, guess and mixed verdicts" do
    verdict(:reimport_row, "hold:row:1", {"user_id" => 1, "from_book_id" => 101, "to_book_id" => 102, "moved" => {}}, applied_at: nil)
    verdict(:reimport_row, "hold:row:2", {"user_id" => 2, "from_book_id" => 201, "to_book_id" => 202, "leftovers_removed" => []}, status: :rejected)
    verdict(:reimport_row, "hold:row:3", {"user_id" => 3, "from_book_id" => 301, "to_book_id" => 302})
    verdict(:reimport_guess, "hold:guess:1", {"user_id" => 4, "from_book_id" => 401, "to_book_id" => 402, "moved" => {}})
    verdict(:reimport_mixed, "hold:mixed:1", {"book_id" => 50, "deleted" => [{"id" => 1, "user_id" => 9}]})

    verdict(:reimport_guess, "hold:guess:2", {"user_id" => 6, "from_book_id" => 701, "to_book_id" => 702, "moved" => {}}, superseded_at: Time.current)
    verdict(:reimport_row, "hold:row:4", {"user_id" => 5, "from_book_id" => 601, "to_book_id" => 602, "moved" => {}})
    verdict(:reimport_mixed, "hold:mixed:2", {"book_id" => 603})
    redirects = Services::BooksMigration::Redirects.new([
      ["Books::Book", 50, 77], ["Books::Book", 602, 603], ["Books::Book", 603, 604]
    ])

    subject = Services::BooksMigration::ReimportHold.load(redirects: redirects)

    assert subject.held?(1, 101)
    assert subject.held?(1, 102)
    assert subject.held?(2, 201)
    assert subject.held?(2, 202)
    assert_not subject.held?(3, 301)
    assert_not subject.held?(3, 302)
    assert subject.held?(4, 401)
    assert subject.held?(4, 402)
    assert subject.held?(9, 50)
    assert_not subject.held?(9, 77)
    assert subject.held?(6, 701)
    assert subject.held?(6, 702)
    assert subject.held?(5, 603)
    assert_not subject.held?(5, 604)
    assert_equal 12, subject.size
  end

  test "none holds nothing" do
    subject = Services::BooksMigration::ReimportHold.none

    assert_not subject.held?(1, 1)
    assert_equal 0, subject.size
  end
end
