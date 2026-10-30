# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsRebuild
      class RetireLumpVerdictsTest < ActiveSupport::TestCase
        setup do
          @base = Cohort.post_import_range.first + 9_000
          @next_id = 0
          @lump_fix = verdict_for(book(:lump), :fix_identity, "book_id")
          @lump_merge = verdict_for(book(:lump), :merge_books, "source_id")
          @coherent = verdict_for(book(:coherent), :fix_identity, "book_id")
          @applied = verdict_for(book(:lump), :fix_identity, "book_id", applied_at: 1.day.ago)
          @foreign = ::Books::RepairVerdict.create!(kind: :fix_identity, subject_key: "other:#{@lump_fix.payload["book_id"]}", status: :proposed,
            decided_by: :rule, payload: {"book_id" => @lump_fix.payload["book_id"]})
        end

        def book(classification)
          book = ::Books::Book.create!(id: @base + (@next_id += 1), title: "Book #{@next_id}")
          groups = [{"titles" => ["Psychology of Money"], "row_count" => 57}, {"titles" => ["The Price of Salt"], "row_count" => 19}]
          ::Books::RebuildBookSurvey.create!(book: book, classification: classification, groups: groups, title_agrees: false,
            authors_agree: false, wrong_book: true, surveyed_at: Time.current)
          book
        end

        def verdict_for(book, kind, key, applied_at: nil)
          ::Books::RepairVerdict.create!(kind: kind, subject_key: "rebuild:#{book.id}", status: :proposed, decided_by: :rule,
            payload: {key => book.id}, applied_at: applied_at)
        end

        def lump_with(kind:, status:, key:)
          book = book(:lump)
          ::Books::RepairVerdict.create!(kind: kind, subject_key: "rebuild:#{book.id}", status: status, decided_by: :rule, payload: {key => book.id})
        end

        def snapshot = ::Books::RepairVerdict.order(:id).pluck(:status, :superseded_at, :reviewed_at, :reason)

        test "dry run counts the lump verdicts and changes nothing" do
          before = snapshot
          result = RetireLumpVerdicts.call

          assert_equal({"fix_identity proposed" => 1, "merge_books proposed" => 1}, result.data[:counts])
          assert_equal 1, result.data[:already_applied]
          assert_equal 2, result.data[:samples].size
          assert_match(/"Psychology of Money" \(57\) \| "The Price of Salt" \(19\)/, result.data[:samples].first)
          refute result.data[:applied]
          assert_equal before, snapshot
        end

        test "apply rejects and supersedes the unapplied lump verdicts only" do
          result = RetireLumpVerdicts.call(apply: true)

          assert result.data[:applied]
          [@lump_fix, @lump_merge].each do |verdict|
            verdict.reload
            assert_predicate verdict, :rejected?
            assert_not_nil verdict.superseded_at
            assert_not_nil verdict.reviewed_at
            assert_match(/split step/, verdict.reason)
          end
          [@coherent, @applied, @foreign].each do |verdict|
            verdict.reload
            assert_predicate verdict, :proposed?
            assert_nil verdict.superseded_at
          end
        end

        test "an approved unapplied lump verdict is retired, an admin-rejected one is left as it is" do
          approved = lump_with(kind: :fix_identity, status: :approved, key: "book_id")
          rejected = lump_with(kind: :merge_books, status: :rejected, key: "source_id")
          rejected_before = rejected.reload.attributes

          result = RetireLumpVerdicts.call(apply: true)

          assert_equal({"fix_identity proposed" => 1, "fix_identity approved" => 1, "merge_books proposed" => 1}, result.data[:counts])
          assert_predicate approved.reload, :rejected?
          assert_not_nil approved.superseded_at
          assert_equal rejected_before, rejected.reload.attributes
        end

        test "a merge from a coherent book into a lump target is not retired" do
          source = book(:coherent)
          into_lump = ::Books::RepairVerdict.create!(kind: :merge_books, subject_key: "rebuild:#{source.id}", status: :proposed, decided_by: :rule,
            payload: {"source_id" => source.id, "target_id" => book(:lump).id})

          RetireLumpVerdicts.call(apply: true)

          assert_predicate into_lump.reload, :proposed?
          assert_nil into_lump.superseded_at
        end

        # An applied merge destroys its source book and the survey with it, so "already applied" cannot see it.
        test "an applied verdict whose subject book and survey are gone is counted apart and left alone" do
          gone = @base + 500
          applied = ::Books::RepairVerdict.create!(kind: :merge_books, subject_key: "rebuild:#{gone}", status: :approved, decided_by: :rule,
            payload: {"source_id" => gone}, applied_at: 1.day.ago)
          pending = ::Books::RepairVerdict.create!(kind: :merge_books, subject_key: "rebuild:#{gone + 1}", status: :proposed, decided_by: :rule,
            payload: {"source_id" => gone + 1})
          before = [applied, pending].map { |v| v.reload.attributes }

          result = RetireLumpVerdicts.call(apply: true)

          assert_equal 1, result.data[:applied_unknown]
          assert_equal ["rebuild:#{gone}"], result.data[:applied_unknown_keys]
          assert_equal before, [applied, pending].map { |v| v.reload.attributes }
          assert_equal 1, result.data[:already_applied]
        end

        test "a second apply finds nothing" do
          RetireLumpVerdicts.call(apply: true)
          before = snapshot

          assert_equal({}, RetireLumpVerdicts.call(apply: true).data[:counts])
          assert_equal before, snapshot
        end
      end
    end
  end
end
