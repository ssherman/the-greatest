# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Verification
      class RevertSecondChanceTest < ActiveSupport::TestCase
        setup do
          @book = books_books(:war_and_peace)
          @at = 1.hour.ago
        end

        def keys(type) = @book.identifiers.where(identifier_type: type).order(:value).pluck(:value)

        def settled_row(prior: :unsure, lookup: :resolve_candidate, **attrs)
          ::Books::Verification.create!({book: @book, work_outcome: :replaced, run_id: "run-2", lookup: lookup, stage: :done,
                                         second_chance_at: @at, prior_outcome: ::Books::Verification.work_outcomes[prior], prior_keys: [],
                                         old_keys: [], new_key: "OL1W"}.merge(attrs))
        end

        test "reverts an unsure row: new and duplicate keys go, prior keys return legacy, later records go, earlier ones stay" do
          ::Identifier.create!(identifiable: @book, identifier_type: ApplyBook::WORK_KEY, value: "OL1W", source: :open_library)
          ::Identifier.create!(identifiable: @book, identifier_type: ApplyBook::WORK_KEY, value: "OL5W", source: :open_library)
          ::Identifier.create!(identifiable: @book, identifier_type: ApplyBook::DUPLICATE_KEY, value: "OL2W", source: :open_library)
          row = settled_row(prior_keys: ["OL5W"], old_keys: ["OL5W"], duplicate_keys: ["OL2W"])
          early = ::Identifier.create!(identifiable: @book, identifier_type: :books_work_oclc_id, value: "11")
          late = ::Identifier.create!(identifiable: @book, identifier_type: :books_work_oclc_id, value: "22")
          before = ::Books::VerificationFinding.create!(verification: row, book: @book, kind: :added, identifier_type: :books_work_oclc_id,
            value: "11", identifier_id: early.id, created_at: @at - 1.day)
          ::Books::VerificationFinding.create!(verification: row, book: @book, kind: :added, identifier_type: :books_work_oclc_id,
            value: "22", identifier_id: late.id, created_at: @at + 1.minute)
          ::Books::EditionCandidate.create!(book: @book, edition_key: "OL1M", created_at: @at - 1.day)
          ::Books::EditionCandidate.create!(book: @book, edition_key: "OL2M", created_at: @at + 1.minute)

          result = RevertSecondChance.call(book: @book)

          assert result.success?
          row.reload
          assert_equal [["OL5W"], [], ["legacy"]], [keys(ApplyBook::WORK_KEY), keys(ApplyBook::DUPLICATE_KEY),
            @book.identifiers.where(identifier_type: ApplyBook::WORK_KEY).pluck(:source)]
          assert_equal [[before.id], ["OL1M"]], [row.findings.pluck(:id), ::Books::EditionCandidate.where(book_id: @book.id).pluck(:edition_key)]
          assert_equal ["11"], keys(:books_work_oclc_id)
          assert_equal ["unsure", "resolve", nil, "done", nil, nil, []],
            [row.work_outcome, row.lookup, row.new_key, row.stage, row.second_chance_at, row.prior_outcome, row.prior_keys]
          assert_equal [], row.duplicate_keys
        end

        test "a removed row reverts to removed and its removed key is not recreated" do
          ::Identifier.create!(identifiable: @book, identifier_type: ApplyBook::WORK_KEY, value: "OL1W", source: :open_library)
          row = settled_row(prior: :removed, prior_keys: [], old_keys: ["OL9W"])

          assert RevertSecondChance.call(book: @book).success?

          assert_equal [[], "removed"], [keys(ApplyBook::WORK_KEY), row.reload.work_outcome]
        end

        test "a row with no second_chance_at fails with a message" do
          row = settled_row(second_chance_at: nil, prior_outcome: nil)

          result = RevertSecondChance.call(book: @book)

          refute result.success?
          assert_match(/second chance/, result.errors.join)
          assert_equal "replaced", row.reload.work_outcome
        end

        test "route reverts only that route's rows; a first-pass settle takes the full revert" do
          other = books_books(:crime_and_punishment)
          third = books_books(:got)
          settled_row
          ::Books::Verification.create!(book: other, work_outcome: :keyed, run_id: "run-2", lookup: :exact_title, stage: :done,
            second_chance_at: @at, prior_outcome: 5, new_key: "OL3W")
          first_pass = ::Books::Verification.create!(book: third, work_outcome: :keyed, run_id: "run-1", lookup: :resolve_candidate,
            stage: :done, new_key: "OL4W")

          counts = RevertSecondChance.route(:resolve_candidate)

          assert_equal({reverted: 2, failed: 0}, counts)
          assert_equal "reverted", first_pass.reload.work_outcome
          assert_equal "unsure", ::Books::Verification.find_by(book: @book).work_outcome
          assert_equal "keyed", ::Books::Verification.find_by(book: other).work_outcome
        end
      end
    end
  end
end
