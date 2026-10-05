require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      class RecordVerdictTest < ActiveSupport::TestCase
        def record(**overrides)
          RecordVerdict.call(kind: :merge_books, subject_key: "books:1:2", payload: {"source_id" => 2, "target_id" => 1},
            decided_by: :rule, confidence: :certain, reason: "same title, authors and ISBN", **overrides)
        end

        test "a new finding is proposed, or approved when the rule is certain enough to apply on its own" do
          proposed = record(auto: false)
          assert_equal :created, proposed.data[:outcome]
          assert_predicate proposed.data[:verdict], :proposed?

          auto = record(subject_key: "books:3:4", auto: true)
          assert_predicate auto.data[:verdict], :approved?
          assert_predicate auto.data[:verdict], :decided_by_rule?
        end

        test "an unreviewed verdict found again takes the new evidence" do
          record(auto: true)
          result = record(payload: {"source_id" => 1, "target_id" => 2}, reason: "newer", auto: false)

          verdict = result.data[:verdict]
          assert_equal :updated, result.data[:outcome]
          assert_equal({"source_id" => 1, "target_id" => 2}, verdict.payload)
          assert_equal "newer", verdict.reason
          assert_predicate verdict, :proposed?
          assert_equal 1, ::Books::RepairVerdict.count
        end

        test "a rejected verdict suppresses its finding" do
          verdict = record.data[:verdict]
          verdict.update!(status: :rejected, decided_by_user_id: users(:admin_user).id, reviewed_at: Time.current)

          result = record(payload: {"source_id" => 9, "target_id" => 1}, auto: true)

          assert_equal :suppressed, result.data[:outcome]
          assert_predicate verdict.reload, :rejected?
          assert_equal({"source_id" => 2, "target_id" => 1}, verdict.payload)
        end

        test "an admin's approval is kept as the admin left it" do
          verdict = record.data[:verdict]
          verdict.update!(status: :approved, decided_by_user_id: users(:admin_user).id, reviewed_at: Time.current)

          result = record(payload: {"source_id" => 9, "target_id" => 1}, auto: false)

          assert_equal :kept, result.data[:outcome]
          assert_predicate verdict.reload, :approved?
          assert_equal({"source_id" => 2, "target_id" => 1}, verdict.payload)
        end

        test "the same key under another kind is another verdict" do
          record
          record(kind: :merge_authors)

          assert_equal 2, ::Books::RepairVerdict.where(subject_key: "books:1:2").count
        end
      end
    end
  end
end
