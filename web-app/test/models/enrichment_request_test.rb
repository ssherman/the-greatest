require "test_helper"

# == Schema Information
#
# Table name: enrichment_requests
#
#  id               :bigint           not null, primary key
#  answer           :jsonb
#  attempts         :integer          default(0), not null
#  enrichable_type  :string           not null
#  error            :text
#  fingerprint      :string
#  kind             :string           not null
#  lease_expires_at :datetime
#  lease_token      :string
#  note             :text
#  outcome          :string
#  priority         :integer          default(1000000), not null
#  reason           :string           not null
#  resolved_at      :datetime
#  resolved_via     :integer
#  sources          :jsonb            not null
#  status           :integer          default(0), not null
#  version          :integer          default(1), not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  claimed_by_id    :bigint
#  enrichable_id    :bigint           not null
#  enrichment_id    :bigint
#  resolved_by_id   :bigint
#
# Indexes
#
#  idx_on_kind_status_priority_id_ac9b960249          (kind,status,priority,id)
#  index_enrichment_requests_on_claimed_by_id         (claimed_by_id)
#  index_enrichment_requests_on_enrichment_id         (enrichment_id)
#  index_enrichment_requests_on_resolved_by_id        (resolved_by_id)
#  index_enrichment_requests_one_per_record_and_kind  (enrichable_type,enrichable_id,kind) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (claimed_by_id => users.id) ON DELETE => nullify
#  fk_rails_...  (enrichment_id => enrichments.id) ON DELETE => nullify
#  fk_rails_...  (resolved_by_id => users.id) ON DELETE => nullify
#
class EnrichmentRequestTest < ActiveSupport::TestCase
  test "one row per record and kind" do
    book = books_books(:war_and_peace)
    EnrichmentRequest.create!(enrichable: book, kind: "books.origin", reason: "missing")
    assert_raises(ActiveRecord::RecordNotUnique) do
      EnrichmentRequest.create!(enrichable: book, kind: "books.origin", reason: "missing")
    end
  end

  test "kind must look like a ledger kind and reason must be known" do
    row = EnrichmentRequest.new(enrichable: books_books(:war_and_peace), kind: "Origin", reason: "because")
    assert_not row.valid?
    assert row.errors[:kind].any?
    assert row.errors[:reason].any?
  end

  test "claimable is pending rows and claimed rows whose lease ran out" do
    book, other, third = books_books(:war_and_peace), books_books(:crime_and_punishment), books_books(:got)
    pending = EnrichmentRequest.create!(enrichable: book, kind: "books.origin", reason: "missing")
    expired = EnrichmentRequest.create!(enrichable: other, kind: "books.origin", reason: "missing", status: :claimed, lease_expires_at: 1.minute.ago)
    held = EnrichmentRequest.create!(enrichable: third, kind: "books.origin", reason: "missing", status: :claimed, lease_expires_at: 10.minutes.from_now)
    assert_equal [pending.id, expired.id].sort, EnrichmentRequest.claimable.pluck(:id).sort
    assert_not_includes EnrichmentRequest.claimable, held
  end

  test "deleting the book deletes its rows" do
    book = ::Books::Book.create!(title: "Gone")
    EnrichmentRequest.create!(enrichable: book, kind: "books.origin", reason: "missing")
    assert_difference -> { EnrichmentRequest.count }, -1 do
      book.destroy!
    end
  end

  test "resolved_via is prefixed so it does not shadow Kernel#system" do
    assert EnrichmentRequest.new(resolved_via: :system).resolved_via_system?
    assert_equal Kernel, EnrichmentRequest.method(:system).owner
  end

  test "REOPEN_RESET returns a resolved row to a clean pending state" do
    user = users(:regular_user)
    row = EnrichmentRequest.create!(
      enrichable: books_books(:war_and_peace), kind: "books.origin", reason: "missing",
      status: :done, attempts: 2, outcome: "applied", note: "n", answer: {"a" => 1}, error: "e",
      sources: ["https://example.com"], lease_token: "t", lease_expires_at: 1.hour.ago,
      claimed_by: user, resolved_by: user, resolved_via: :api, resolved_at: Time.current
    )
    EnrichmentRequest.where(id: row.id).update_all(EnrichmentRequest::REOPEN_RESET.merge(reason: "version", version: 2))
    row.reload
    assert row.pending?
    assert_equal [0, "version", 2, []], [row.attempts, row.reason, row.version, row.sources]
    assert_equal [nil] * 10, [row.outcome, row.note, row.answer, row.error, row.enrichment_id, row.lease_token,
      row.lease_expires_at, row.claimed_by_id, row.resolved_by_id, row.resolved_via]
    assert_nil row.resolved_at
  end

  test "carry_over moves the source's rows and drops one the target already has" do
    source, target = books_books(:war_and_peace), books_books(:crime_and_punishment)
    moved = EnrichmentRequest.create!(enrichable: source, kind: "books.origin", reason: "missing")
    EnrichmentRequest.create!(enrichable: source, kind: "books.categories", reason: "missing")
    kept = EnrichmentRequest.create!(enrichable: target, kind: "books.categories", reason: "missing", status: :done)
    assert_equal 1, EnrichmentRequest.carry_over(source: source, target: target)
    assert_equal target, moved.reload.enrichable
    assert_equal [kept.id], EnrichmentRequest.where(enrichable: target, kind: "books.categories").pluck(:id)
    assert_empty EnrichmentRequest.where(enrichable: source).to_a
  end
end
