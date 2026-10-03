# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class BackfillTest < ActiveSupport::TestCase
        def setup
          # Sidekiq runs inline in tests: record the enqueues instead.
          @wikidata_calls = []
          @viaf_calls = []
          ::Books::Authors::WikidataJob.stubs(:perform_in).with { |*args| @wikidata_calls << args }
          ::Books::Authors::ViafJob.stubs(:perform_async).with { |*args| @viaf_calls << args }
        end

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

        def queued_ids = @wikidata_calls.map { |args| args[1] }

        def backfill(limit: nil, queued: Set.new) = Backfill.call(limit: limit, queued: queued)

        test "queues unprocessed authors ranked first by rank, then by books written, at the Wikidata pace with research off" do
          second = author("Second Ranked", rank: 2)
          first = author("First Ranked", rank: 1)
          single = author("Single", books: 1)
          prolific = author("Prolific", books: 3)

          backfill

          assert_equal [first.id, second.id, prolific.id, single.id], queued_ids & [first.id, second.id, prolific.id, single.id]
          assert_equal (0...@wikidata_calls.size).map { |index| index * Backfill::SPACING }, @wikidata_calls.map(&:first)
          assert(@wikidata_calls.all? { |args| args[2..] == [false, false, false] })
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

          result = backfill(limit: 1, queued: Set[waiting.id])

          assert_equal [next_up.id], queued_ids
          assert_equal [1, 1], result.data.values_at(:wikidata, :left_out)
        end

        test "a Wikidata miss whose VIAF step never finished gets the VIAF step again, with the AI step marked already queued" do
          missed = author("Missed").tap do |a|
            done(a, outcome: :unrecognized) && done(a, kind: EnrichFromViaf::KIND, outcome: :failed) && done(a, kind: EnrichAuthor::KIND)
          end
          viaf_done = author("VIAF Done").tap { |a| done(a, outcome: :unrecognized) && done(a, kind: EnrichFromViaf::KIND, outcome: :unrecognized) }
          matched_later = author("Matched Later").tap { |a| done(a, outcome: :unrecognized) && done(a, outcome: :applied) }

          backfill

          ours = @viaf_calls.select { |args| [missed.id, viaf_done.id, matched_later.id].include?(args.first) }
          assert_equal [[missed.id, false, true, false]], ours
          assert_not_includes queued_ids, missed.id
        end

        test "a VIAF-retry author whose only AI-step row this era failed is not marked already queued" do
          failed_ai = author("Failed AI").tap do |a|
            done(a, outcome: :unrecognized) && done(a, kind: EnrichFromViaf::KIND, outcome: :failed) && done(a, kind: EnrichAuthor::KIND, outcome: :failed)
          end

          backfill

          ours = @viaf_calls.select { |args| args.first == failed_ai.id }
          assert_equal [[failed_ai.id, false, false, false]], ours
        end

        test "a Wikidata miss with no VIAF row and no AI step this era is a lost chain: the AI step is not marked already queued" do
          lost = author("Lost").tap { |a| done(a, outcome: :unrecognized) }

          backfill

          ours = @viaf_calls.select { |args| args.first == lost.id }
          assert_equal [[lost.id, false, false, false]], ours
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
