# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class BackfillTest < ActiveSupport::TestCase
        def setup
          # Sidekiq runs inline in tests: plan the runs without executing them.
          stub_workflow_dispatch
          freeze_time
        end

        def planned = ::WorkflowRun.where(initiated_by: "backfill").order(:id)

        # The runs from the start (Wikidata first) and the runs that start at VIAF.
        def wikidata_runs = planned.reject { |run| run.options["start_at"] }

        def viaf_runs = planned.select { |run| run.options["start_at"] == "viaf" }

        def author(name, books: 0, rank: nil)
          created = ::Books::Author.create!(name: name)
          books.times { |index| created.book_authors.create!(book: ::Books::Book.create!(title: "#{name} book #{index}"), position: 1) }
          if rank
            RankedItem.create!(item: created, ranking_configuration: ranking_configurations(:books_authors_global), rank: rank, score: 100 - rank)
          end
          created
        end

        def done(author, kind: EnrichFromWikidata::KIND, outcome: :applied, decision: nil)
          author.enrichments.create!(kind: kind, outcome: outcome, match_decision: decision, created_at: author.created_at + 1.minute)
        end

        def queued_ids = wikidata_runs.map(&:enrichable_id)

        def backfill(limit: nil, queued: Set.new) = Backfill.call(limit: limit, queued: queued)

        test "plans unprocessed authors ranked first by rank, then by books written, spaced at the Wikidata pace with research off" do
          second = author("Second Ranked", rank: 2)
          first = author("First Ranked", rank: 1)
          single = author("Single", books: 1)
          prolific = author("Prolific", books: 3)

          backfill

          assert_equal [first.id, second.id, prolific.id, single.id], queued_ids & [first.id, second.id, prolific.id, single.id]
          assert_equal (0...wikidata_runs.size).map { |index| Time.current + (index * Backfill::SPACING).seconds },
            wikidata_runs.map { |run| run.step(:wikidata).run_after }
          assert(wikidata_runs.all? { |run| run.options == {"allow_research" => false} })
        end

        test "leaves out processed authors and placeholders; a failed run or a rejected one leaves an author in" do
          processed = author("Processed").tap { |a| done(a) }
          placeholder = ::Books::Author.create!(name: "Placeholder", exclude_from_rankings: true)
          failed = author("Failed").tap { |a| done(a, outcome: :failed) }
          rejected = author("Rejected")
          decision = ::MatchDecision.create!(finder: ResolveWikidata.name, subject: rejected, outcome: :matched, confidence: :high,
            decided_by: :rule, verdict: :rejected, candidates: [{"external_key" => "Q1"}], selected_index: 1)
          done(rejected, decision: decision)

          backfill

          assert_equal [failed.id, rejected.id].sort, (queued_ids & [processed.id, placeholder.id, failed.id, rejected.id]).sort
        end

        test "an author with a chain job already waiting is left out and counted, and the limit counts only the rest" do
          waiting = author("Waiting", rank: 1)
          next_up = author("Next", rank: 2)
          author("After", rank: 3)
          # The fixtures hold an active run for an author this also leaves out.
          fixture_runs = Backfill.unprocessed.where(id: ::WorkflowRun.running.select(:enrichable_id)).count

          result = backfill(limit: 1, queued: Set[waiting.id])

          assert_equal [next_up.id], queued_ids
          assert_equal [1, 1 + fixture_runs], result.data.values_at(:wikidata, :left_out)
        end

        test "a Wikidata miss whose VIAF step never finished gets a run starting at VIAF, with the AI step skipped if it ran" do
          missed = author("Missed").tap do |a|
            done(a, outcome: :unrecognized) && done(a, kind: EnrichFromViaf::KIND, outcome: :failed) && done(a, kind: EnrichAuthor::KIND)
          end
          viaf_done = author("VIAF Done").tap { |a| done(a, outcome: :unrecognized) && done(a, kind: EnrichFromViaf::KIND, outcome: :unrecognized) }
          matched_later = author("Matched Later").tap { |a| done(a, outcome: :unrecognized) && done(a, outcome: :applied) }

          backfill

          ours = viaf_runs.select { |run| [missed.id, viaf_done.id, matched_later.id].include?(run.enrichable_id) }
          assert_equal [missed.id], ours.map(&:enrichable_id)
          assert_equal({"allow_research" => false, "start_at" => "viaf", "skip_ai_if_ran" => true}, ours.first.options)
          assert_not_includes queued_ids, missed.id
        end

        test "an author with an active run is left out, whatever Sidekiq holds, and the run is left alone" do
          active = author("Active", rank: 1)
          next_up = author("Next", rank: 2)
          existing = ::Workflows::Books::AuthorEnrichment.start(active, initiated_by: "test")

          result = backfill

          assert_not_includes queued_ids, active.id
          assert_includes queued_ids, next_up.id
          assert_operator result.data[:left_out], :>=, 1
          assert_equal [existing.id], ::WorkflowRun.where(enrichable: active).pluck(:id)
        end

        test "with no queued set given, the production path reads the chain Sidekiq itself has waiting" do
          waiting = author("Waiting", rank: 1)
          next_up = author("Next", rank: 2)
          QueuedChain.stubs(:author_ids).returns(Set[waiting.id])

          Backfill.call(limit: nil)

          assert_not_includes queued_ids, waiting.id
          assert_includes queued_ids, next_up.id
        end

        test "unprocessed counts the authors a full run would queue for the Wikidata step" do
          fresh = author("Fresh")
          processed = author("Processed").tap { |a| done(a) }

          ids = Backfill.unprocessed.pluck(:id)

          assert_includes ids, fresh.id
          assert_not_includes ids, processed.id
        end
      end
    end
  end
end
