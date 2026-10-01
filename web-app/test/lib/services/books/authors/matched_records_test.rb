# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class MatchedRecordsTest < ActiveSupport::TestCase
        WIKIDATA_EVIDENCE = {"description" => "American writer", "occupations" => ["novelist"]}.freeze

        def setup
          @author = ::Books::Author.create!(name: "Stacy Willingham")
        end

        # The decision's second candidate is the selected one, so a wrong
        # index would pick "someone-else".
        def decision(finder, key:, evidence:, outcome: :matched)
          ::MatchDecision.create!(
            finder: finder, subject: @author, outcome: outcome, confidence: :high, decided_by: :rule,
            candidates: [{"external_key" => "someone-else", "evidence" => {}}, {"external_key" => key, "evidence" => evidence}],
            selected_index: (outcome == :matched) ? 2 : nil
          )
        end

        def ledger_row(kind, decision:, outcome: :applied, reason: "matched", facts: {})
          @author.enrichments.create!(kind: kind, provider: "test", outcome: outcome, reason: reason, facts: facts,
            match_decision: decision)
        end

        def wikidata_match(facts: {}, **options)
          ledger_row(EnrichFromWikidata::KIND, decision: decision(ResolveWikidata.name, key: "Q1", evidence: WIKIDATA_EVIDENCE),
            facts: facts, **options)
        end

        def store_lead(item:)
          ::ExternalRecord.create!(source: :wikipedia, source_id: "en:9", fetched_at: Time.current, payload: {
            "language" => "en", "page_id" => 9, "title" => "Stacy Willingham",
            "url" => "https://en.wikipedia.org/wiki/Stacy_Willingham", "extract" => "Stacy Willingham is an American author.",
            "wikibase_item" => item, "disambiguation" => false
          })
        end

        def linked_page
          {"wikipedia" => {"value" => "https://en.wikipedia.org/wiki/Stacy_Willingham", "applied" => true, "reason" => "linked",
                           "page" => "en:9"}}
        end

        test "the Wikidata match is the candidate the latest processed row's decision selected" do
          wikidata_match
          records = MatchedRecords.new(@author)

          assert_equal ["Q1", WIKIDATA_EVIDENCE], [records.wikidata.source_id, records.wikidata.evidence]
          assert records.matched?
          assert_nil records.viaf
        end

        test "a later run that matched nothing replaces an earlier match" do
          wikidata_match
          ledger_row(EnrichFromWikidata::KIND, decision: decision(ResolveWikidata.name, key: nil, evidence: {}, outcome: :unmatched),
            outcome: :unrecognized, reason: "no_match")

          assert_nil MatchedRecords.new(@author).wikidata
          refute MatchedRecords.new(@author).matched?
        end

        test "a failed or skipped row is not processed, so an earlier match stands" do
          wikidata_match
          ledger_row(EnrichFromWikidata::KIND, decision: nil, outcome: :failed, reason: "wikimedia_error")
          ledger_row(EnrichFromWikidata::KIND, decision: nil, outcome: :skipped, reason: "already_processed")

          assert_equal "Q1", MatchedRecords.new(@author).wikidata.source_id
        end

        test "a matched run that applied nothing still counts" do
          wikidata_match(outcome: :nothing_to_apply, reason: "matched Q1")

          assert_equal "Q1", MatchedRecords.new(@author).wikidata.source_id
        end

        test "a held id that conflicted with the match contributes nothing" do
          wikidata_match(outcome: :nothing_to_apply, reason: "held_qid_conflict")

          assert_nil MatchedRecords.new(@author).wikidata
        end

        test "a row older than the author row does not count" do
          wikidata_match.update_columns(created_at: @author.created_at - 1.minute)

          assert_nil MatchedRecords.new(@author).wikidata
        end

        test "the VIAF match comes from the VIAF step's rows" do
          ledger_row(EnrichFromViaf::KIND, decision: decision(ResolveViaf.name, key: "5391", evidence: {"agency_count" => 20}))
          records = MatchedRecords.new(@author)

          assert_equal ["5391", {"agency_count" => 20}], [records.viaf.source_id, records.viaf.evidence]
          assert_nil records.wikidata
          assert records.matched?
        end

        test "the lead is the page the matched Wikidata run linked, and it is listed in the sources" do
          store_lead(item: "Q1")
          wikidata_match(facts: linked_page)
          records = MatchedRecords.new(@author)

          assert_equal "Stacy Willingham is an American author.", records.lead.extract
          assert_equal [{"source" => "wikidata", "source_id" => "Q1"}, {"source" => "wikipedia", "source_id" => "en:9"}],
            records.sources
        end

        test "a stored page that names another item is not the lead" do
          store_lead(item: "Q2")
          wikidata_match(facts: linked_page)

          assert_nil MatchedRecords.new(@author).lead
        end

        test "an author nothing matched has no lead and no sources" do
          records = MatchedRecords.new(@author)

          assert_nil records.lead
          assert_equal [], records.sources
          refute records.matched?
        end
      end
    end
  end
end
