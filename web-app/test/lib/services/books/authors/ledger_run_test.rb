# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class LedgerRunTest < ActiveSupport::TestCase
        KIND = EnrichFromWikidata::KIND

        def author(name) = ::Books::Author.create!(name: name)

        def row(author, outcome, kind: KIND, at: author.created_at + 1.minute, decision: nil)
          author.enrichments.create!(kind: kind, outcome: outcome, match_decision: decision, created_at: at)
        end

        def processed_ids(kind = KIND) = LedgerRun.processed(kind).pluck(:enrichable_id).sort

        test "a done outcome counts; a failed or skipped row does not" do
          done = author("Done").tap { |a| row(a, :unrecognized) }
          failed = author("Failed").tap { |a| row(a, :failed) }
          skipped = author("Skipped").tap { |a| row(a, :skipped) }

          assert_equal [done.id], processed_ids & [done.id, failed.id, skipped.id]
        end

        test "only a row newer than its own author row counts (a re-migrated author starts again)" do
          remigrated = author("Re-migrated").tap { |a| row(a, :applied, at: a.created_at - 1.day) }
          current = author("Current").tap { |a| row(a, :applied) }

          assert_equal [current.id], processed_ids & [remigrated.id, current.id]
        end

        test "a row whose decision a person rejected does not count; a row with no decision does" do
          rejected = author("Rejected")
          decision = ::MatchDecision.create!(finder: ResolveWikidata.name, subject: rejected, outcome: :matched, confidence: :high,
            decided_by: :rule, verdict: :rejected, candidates: [{"external_key" => "Q1"}], selected_index: 1)
          row(rejected, :applied, decision: decision)
          undecided = author("No decision").tap { |a| row(a, :unrecognized) }

          assert_equal [undecided.id], processed_ids & [rejected.id, undecided.id]
        end

        test "only rows of the kind asked for" do
          wikidata = author("Wikidata").tap { |a| row(a, :applied) }
          viaf = author("VIAF").tap { |a| row(a, :applied, kind: EnrichFromViaf::KIND) }

          assert_equal [[wikidata.id], [viaf.id]],
            [processed_ids & [wikidata.id, viaf.id], processed_ids(EnrichFromViaf::KIND) & [wikidata.id, viaf.id]]
        end
      end
    end
  end
end
