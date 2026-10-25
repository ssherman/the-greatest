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
          ::Identifier.create!(identifiable: @book, identifier_type: ApplyBook::DUPLICATE_KEY, value: "OL2W", source: :open_library)
          row = settled_row(prior_keys: ["OL5W"], old_keys: ["OL5W"], duplicate_keys: ["OL2W"])
          early = ::Identifier.create!(identifiable: @book, identifier_type: :books_work_oclc_id, value: "11")
          late = ::Identifier.create!(identifiable: @book, identifier_type: :books_work_oclc_id, value: "22")
          before = ::Books::VerificationFinding.create!(verification: row, book: @book, kind: :added, identifier_type: :books_work_oclc_id,
            value: "11", identifier_id: early.id, created_at: @at - 1.day, updated_at: @at - 1.day)
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

        # Death in Venice in the dev rehearsal: the alternate-titles cleanup undid
        # a first-pass finding, the second chance found the identifier again and
        # Stamp reused the row (one row per verification, kind, type and value),
        # so it is older than second_chance_at but was written after it.
        test "a first-pass finding the second chance wrote again is reverted" do
          row = settled_row
          oclc = ::Identifier.create!(identifiable: @book, identifier_type: :books_work_oclc_id, value: "33", source: :open_library)
          isbn = ::Identifier.create!(identifiable: @book, identifier_type: :books_work_isbn13, value: "9780141181738", source: :open_library)
          ::Books::VerificationFinding.create!(verification: row, book: @book, kind: :added, identifier_type: :books_work_oclc_id,
            value: "33", identifier_id: oclc.id, source: :open_library, created_at: @at - 1.day, updated_at: @at + 1.minute)
          ::Books::VerificationFinding.create!(verification: row, book: @book, kind: :confirmed, identifier_type: :books_work_isbn13,
            value: "9780141181738", identifier_id: isbn.id, source: :open_library, previous_source: :legacy,
            created_at: @at - 1.day, updated_at: @at + 1.minute)

          assert RevertSecondChance.call(book: @book).success?

          assert_equal [[], ["legacy"]], [keys(:books_work_oclc_id), @book.identifiers.where(identifier_type: :books_work_isbn13, value: "9780141181738").pluck(:source)]
        end

        test "a confirmed key is kept under the same identifier and goes back to legacy" do
          held = ::Identifier.create!(identifiable: @book, identifier_type: ApplyBook::WORK_KEY, value: "OL5W", source: :open_library)
          settled_row(work_outcome: :confirmed, new_key: "OL5W", prior_keys: ["OL5W"], old_keys: ["OL5W"])

          assert RevertSecondChance.call(book: @book).success?

          assert_equal [[held.id, "legacy"]], @book.identifiers.where(identifier_type: ApplyBook::WORK_KEY).pluck(:id, :source)
        end

        test "a duplicate_pair settle reverts to the prior outcome, and the route counts it" do
          row = settled_row(prior: :removed, work_outcome: :duplicate_pair, new_key: "OL1W", old_keys: ["OL9W"])

          assert_equal({reverted: 1, failed: 0}, RevertSecondChance.route(:resolve_candidate))
          assert_equal ["removed", nil], [row.reload.work_outcome, row.second_chance_at]
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

        test "author keys the second chance added go" do
          author = books_authors(:tolstoy)
          ::Identifier.create!(identifiable: author, identifier_type: :books_author_openlibrary_id, value: "OL26783A", source: :open_library)
          ::Identifier.create!(identifiable: @book, identifier_type: ApplyBook::WORK_KEY, value: "OL1W", source: :open_library)
          settled_row(lookup: :resolve, work_outcome: :keyed, author_changes: {"added" => [[author.id, "OL26783A"]]})

          assert RevertSecondChance.call(book: @book).success?

          assert_empty author.identifiers.where(identifier_type: :books_author_openlibrary_id)
          assert_equal({}, ::Books::Verification.find_by(book: @book).author_changes)
        end

        test "second_chance_matcher reverts matcher-lookup rows the second chance settled, and nothing else" do
          other = books_books(:crime_and_punishment)
          third = books_books(:got)
          fourth = books_books(:clash)
          settled_row(lookup: :resolve, work_outcome: :keyed)
          ::Books::Verification.create!(book: other, work_outcome: :confirmed, run_id: "run-2", lookup: :identifiers, stage: :done,
            second_chance_at: @at, prior_outcome: 5, new_key: "OL3W")
          first_pass = ::Books::Verification.create!(book: third, work_outcome: :keyed, run_id: "run-1", lookup: :resolve,
            stage: :done, new_key: "OL4W")
          route_row = ::Books::Verification.create!(book: fourth, work_outcome: :keyed, run_id: "run-2", lookup: :held_key, stage: :done,
            second_chance_at: @at, prior_outcome: 5, new_key: "OL5W")

          assert_equal({reverted: 2, failed: 0}, RevertSecondChance.route(:second_chance_matcher))
          assert_equal ["unsure", "unsure", "keyed", "keyed"],
            [@book, other].map { |book| ::Books::Verification.find_by(book: book).work_outcome } + [first_pass.reload.work_outcome, route_row.reload.work_outcome]
        end

        test "an unknown route raises" do
          assert_raises(ArgumentError) { RevertSecondChance.route(:everything) }
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
