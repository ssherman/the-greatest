require "test_helper"

class Books::GoodreadsReimport::RecheckCreatesJobTest < ActiveSupport::TestCase
  MATCH = Services::Books::GoodreadsReimport::MatchEdition

  def result(outcome) = MATCH::Result.new(success?: true, data: {outcome: outcome}, errors: [])

  def edition(number)
    Books::GoodreadsEdition.create!(goodreads_book_id: 71_000 + number, signature: "recheck-sig-#{number}", title: "T#{number}", primary_author: "A")
  end

  def verdict(edition, outcome: "create", status: :approved, **attrs)
    payload = {"goodreads_edition_id" => edition.id, "outcome" => outcome}.merge(attrs.delete(:payload) || {})
    Books::RepairVerdict.create!(kind: :reimport_match, subject_key: "reimport:edition:#{edition.id}", payload: payload,
      decided_by: :ai, confidence: :high, status: status, **attrs)
  end

  setup do
    @config = Rails.configuration.x.goodreads_reimport
    @was = @config.enabled
    @config.enabled = true
  end

  teardown { @config.enabled = @was }

  test "enqueue picks unreviewed, unapplied, current create verdicts without an English check, in batches" do
    picked = [verdict(edition(1)), verdict(edition(2), status: :proposed)]
    verdict(edition(3), outcome: "matched")
    verdict(edition(4), payload: {"english_title" => {"title" => nil}})
    verdict(edition(5), status: :rejected, reviewed_at: Time.current)
    verdict(edition(6), status: :approved, reviewed_at: Time.current)
    verdict(edition(7), applied_at: Time.current)
    verdict(edition(8), superseded_at: Time.current)
    batches = []
    Books::GoodreadsReimport::RecheckCreatesJob.stubs(:perform_async).with { |ids| batches << ids }

    assert_equal 2, Books::GoodreadsReimport::RecheckCreatesJob.enqueue(limit: nil)
    assert_equal [picked.map(&:id)], batches
    assert_equal 1, Books::GoodreadsReimport::RecheckCreatesJob.enqueue(limit: 1)
  end

  test "matches each verdict's edition again as a recheck, leaving the verdict to MatchEdition" do
    ed = edition(1)
    v = verdict(ed)
    MATCH.expects(:call).with(edition: ed, recheck: true).returns(result(:matched))

    Books::GoodreadsReimport::RecheckCreatesJob.new.perform([v.id])

    assert_nil v.reload.superseded_at
  end

  test "an error leaves the verdict a candidate and the batch carries on" do
    a = verdict(edition(1))
    b = verdict(edition(2))
    MATCH.expects(:call).twice.raises(RuntimeError, "boom").then.returns(result(:create))
    Rails.logger.stubs(:error)

    Books::GoodreadsReimport::RecheckCreatesJob.new.perform([a.id, b.id])

    assert Books::GoodreadsReimport::RecheckCreatesJob.candidates.exists?(id: a.id)
  end

  test "a verdict reviewed or applied since it was queued is left alone" do
    v = verdict(edition(1))
    v.update!(reviewed_at: Time.current, status: :rejected)
    MATCH.expects(:call).never

    Books::GoodreadsReimport::RecheckCreatesJob.new.perform([v.id])

    assert_nil v.reload.superseded_at
  end

  test "does nothing while the gate is off" do
    @config.enabled = false
    v = verdict(edition(1))
    MATCH.expects(:call).never

    Books::GoodreadsReimport::RecheckCreatesJob.new.perform([v.id])
  end
end
