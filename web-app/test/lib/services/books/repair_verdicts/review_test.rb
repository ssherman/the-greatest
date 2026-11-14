# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module RepairVerdicts
      class ReviewTest < ActiveSupport::TestCase
        setup do
          @admin = users(:admin_user)
          @book = books_books(:war_and_peace)
        end

        def verdict(key, kind: :relink, status: :proposed, **attrs)
          ::Books::RepairVerdict.create!(kind: kind, subject_key: key, status: status, decided_by: :ai, confidence: :high,
            payload: {"book_id" => @book.id}, reason: "test", **attrs)
        end

        test "approve stamps the status, reviewer, time and surface" do
          v = verdict("a:1")
          freeze_time do
            result = Review.approve(verdict: v, user: @admin, via: "api")

            assert result.success?
            v.reload
            assert_predicate v, :approved?
            assert_equal [@admin.id, Time.current, "api"], [v.decided_by_user_id, v.reviewed_at, v.reviewed_via]
            assert_predicate v, :decided_by_ai?
            assert_nil v.applied_at
          end
        end

        test "approve refuses a verdict that is not proposed and changes nothing" do
          v = verdict("a:2", status: :rejected)

          result = Review.approve(verdict: v, user: @admin, via: "admin_ui")

          refute result.success?
          assert_equal :not_proposed, result.data[:code]
          v.reload
          assert_predicate v, :rejected?
          assert_nil v.reviewed_at
          assert_nil v.reviewed_via
        end

        test "approve checks the stored state, not a stale in-memory copy" do
          v = verdict("a:3")
          ::Books::RepairVerdict.find(v.id).update!(status: :approved)

          result = Review.approve(verdict: v, user: @admin, via: "admin_ui")

          assert_equal :not_proposed, result.data[:code]
          assert_nil v.reload.reviewed_via
        end

        test "reject stamps the status, reviewer, time and surface" do
          v = verdict("r:1")
          freeze_time do
            result = Review.reject(verdict: v, user: @admin, via: "admin_ui")

            assert result.success?
            v.reload
            assert_predicate v, :rejected?
            assert_equal [@admin.id, Time.current, "admin_ui"], [v.decided_by_user_id, v.reviewed_at, v.reviewed_via]
            assert_equal [false, false], [result.data[:applied], result.data[:reverted]]
          end
        end

        test "reject refuses an already rejected verdict" do
          v = verdict("r:2", status: :rejected)

          result = Review.reject(verdict: v, user: @admin, via: "api")

          refute result.success?
          assert_equal :already_rejected, result.data[:code]
          assert_nil v.reload.reviewed_via
        end

        test "rejecting an applied mark_provisional reverts the flag, refreshes rankings and clears applied_at" do
          @book.update!(provisional: true)
          v = verdict("book:#{@book.id}", kind: :mark_provisional, status: :approved, applied_at: Time.current)
          ::Services::RankingConfigurations::RequestRefresh.expects(:call_for_ids).with(anything, delay: 5.minutes).once

          result = Review.reject(verdict: v, user: @admin, via: "api")

          assert result.success?
          assert_equal [true, true], [result.data[:applied], result.data[:reverted]]
          v.reload
          assert_predicate v, :rejected?
          assert_nil v.applied_at
          assert_equal "api", v.reviewed_via
          refute @book.reload.provisional
        end

        test "rejecting an applied verdict of another kind reverts nothing and keeps applied_at" do
          applied_at = 1.day.ago.change(usec: 0)
          v = verdict("m:1", kind: :merge_books, status: :approved, applied_at: applied_at)
          ::Services::Books::GoodreadsReplay::Apply::MarkProvisional.expects(:revert).never

          result = Review.reject(verdict: v, user: @admin, via: "admin_ui")

          assert result.success?
          assert_equal [true, false], [result.data[:applied], result.data[:reverted]]
          assert_equal applied_at, v.reload.applied_at
        end

        test "bulk approve approves only proposed current verdicts and lists the rest as skipped" do
          proposed = verdict("b:1")
          approved = verdict("b:2", status: :approved)
          superseded = verdict("b:3", superseded_at: Time.current)
          missing = 999_999_999

          freeze_time do
            result = Review.bulk_approve(ids: [proposed.id, approved.id, superseded.id, missing], user: @admin, via: "api")

            assert result.success?
            assert_equal [proposed.id], result.data[:approved_ids]
            assert_equal [approved.id, superseded.id, missing].sort, result.data[:skipped_ids].sort
            proposed.reload
            assert_predicate proposed, :approved?
            assert_equal [@admin.id, Time.current, "api"], [proposed.decided_by_user_id, proposed.reviewed_at, proposed.reviewed_via]
          end
          assert_predicate superseded.reload, :proposed?
          assert_nil approved.reload.reviewed_via
        end

        test "bulk approve of nothing succeeds with empty lists" do
          result = Review.bulk_approve(ids: [], user: @admin, via: "admin_ui")

          assert result.success?
          assert_equal [[], []], [result.data[:approved_ids], result.data[:skipped_ids]]
        end
      end
    end
  end
end
