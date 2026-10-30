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

        def snapshot = ::Books::RepairVerdict.order(:id).pluck(:status, :superseded_at, :reviewed_at, :reason)

        test "dry run counts the lump verdicts and changes nothing" do
          before = snapshot
          result = RetireLumpVerdicts.call

          assert_equal({"fix_identity" => 1, "merge_books" => 1}, result.data[:counts])
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

        test "a second apply finds nothing" do
          RetireLumpVerdicts.call(apply: true)
          before = snapshot

          assert_equal({"fix_identity" => 0, "merge_books" => 0}, RetireLumpVerdicts.call(apply: true).data[:counts])
          assert_equal before, snapshot
        end
      end
    end
  end
end
