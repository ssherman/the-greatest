# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsRebuild
      class RetireUnneededFixesTest < ActiveSupport::TestCase
        setup do
          @base = Cohort.post_import_range.first + 9_500
          @next_id = 0
          @none = fix("Euthydemus", "Euthydemus (Hackett Classics)")
          @title_only = fix("Destination", "Destination: Void")
          @full = fix("Ninguno", "Auschwitz and After")
          @applied = fix("Euthydemus", "Euthydemus (Series)", applied_at: 1.day.ago)
          @rejected = fix("Euthydemus", "Euthydemus (Series)", status: :rejected)
        end

        def fix(title, export_title, status: :proposed, applied_at: nil)
          book = ::Books::Book.create!(id: @base + (@next_id += 1), title: title)
          ::Books::RebuildBookSurvey.create!(book: book, classification: :coherent, groups: [], title_agrees: false,
            authors_agree: true, wrong_book: false, surveyed_at: Time.current)
          ::Books::RepairVerdict.create!(kind: :fix_identity, subject_key: "rebuild:#{book.id}", status: status, decided_by: :rule,
            applied_at: applied_at, payload: {"book_id" => book.id, "full_title" => export_title})
        end

        def snapshot = ::Books::RepairVerdict.order(:id).pluck(:status, :superseded_at, :reviewed_at, :reason)

        test "dry run counts the unneeded fixes and changes nothing" do
          before = snapshot
          result = RetireUnneededFixes.call

          assert_equal({"proposed" => 1}, result.data[:counts])
          assert_equal [%(##{@none.payload["book_id"]} "Euthydemus" → "Euthydemus (Hackett Classics)")], result.data[:samples]
          refute result.data[:applied]
          assert_equal before, snapshot
        end

        test "apply retires an unneeded fix and leaves the others alone" do
          other = [@title_only, @full, @applied, @rejected]
          before = other.map { |v| v.reload.attributes }

          RetireUnneededFixes.call(apply: true)

          @none.reload
          assert_predicate @none, :rejected?
          assert_not_nil @none.superseded_at
          assert_not_nil @none.reviewed_at
          assert_equal RetireUnneededFixes::REASON, @none.reason
          assert_equal before, other.map { |v| v.reload.attributes }
        end

        test "an approved unneeded fix is retired too" do
          approved = fix("Euthydemus", "Euthydemus (Series)", status: :approved)

          result = RetireUnneededFixes.call(apply: true)

          assert_equal({"proposed" => 1, "approved" => 1}, result.data[:counts])
          assert_predicate approved.reload, :rejected?
        end

        test "a second apply finds nothing" do
          RetireUnneededFixes.call(apply: true)
          before = snapshot

          assert_empty RetireUnneededFixes.call(apply: true).data[:counts]
          assert_equal before, snapshot
        end
      end
    end
  end
end
