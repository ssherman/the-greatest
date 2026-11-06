# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsRebuild
      class RetireReplayProposalsTest < ActiveSupport::TestCase
        setup do
          @relinks = [verdict(:relink, "r1"), verdict(:relink, "r2")]
          @strip = verdict(:strip_identifier, "s1")
          @approved = verdict(:relink, "r3", status: :approved)
          @merge = verdict(:merge_books, "m1")
        end

        def verdict(kind, key, status: :proposed)
          ::Books::RepairVerdict.create!(kind: kind, subject_key: key, status: status, decided_by: :ai, payload: {})
        end

        def snapshot = ::Books::RepairVerdict.order(:id).pluck(:status, :superseded_at, :updated_at)

        test "dry run counts proposed relinks and strips and changes nothing" do
          before = snapshot
          result = RetireReplayProposals.call

          assert_equal({"relink" => 2, "strip_identifier" => 1}, result.data[:counts])
          refute result.data[:applied]
          assert_equal before, snapshot
        end

        test "apply rejects and supersedes exactly those" do
          result = RetireReplayProposals.call(apply: true)

          assert result.data[:applied]
          (@relinks + [@strip]).each do |verdict|
            verdict.reload
            assert_predicate verdict, :rejected?
            assert_not_nil verdict.superseded_at
          end
          assert_predicate @approved.reload, :approved?
          assert_nil @approved.superseded_at
          assert_predicate @merge.reload, :proposed?
          assert_nil @merge.superseded_at
        end

        # RecordVerdict can turn an unreviewed, auto-approved verdict that was
        # already applied back to proposed while keeping applied_at.
        test "a proposed verdict that was already applied is left alone" do
          applied = verdict(:relink, "r4")
          applied.update!(applied_at: 1.day.ago)

          result = RetireReplayProposals.call(apply: true)

          assert_equal({"relink" => 2, "strip_identifier" => 1}, result.data[:counts])
          assert_predicate applied.reload, :proposed?
          assert_nil applied.superseded_at
        end

        test "a second apply finds nothing" do
          RetireReplayProposals.call(apply: true)

          assert_equal({"relink" => 0, "strip_identifier" => 0}, RetireReplayProposals.call(apply: true).data[:counts])
        end
      end
    end
  end
end
