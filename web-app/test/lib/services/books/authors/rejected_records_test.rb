# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class RejectedRecordsTest < ActiveSupport::TestCase
        def setup
          @author = ::Books::Author.create!(name: "Rejected Records Author")
        end

        def decision(finder, key, author: @author, verdict: :rejected, outcome: :matched)
          ::MatchDecision.create!(
            finder: finder, subject: author, outcome: outcome, confidence: :high, decided_by: :rule, verdict: verdict,
            candidates: [{"external_key" => "other"}, {"external_key" => key}], selected_index: (outcome == :matched) ? 2 : nil
          )
        end

        test "the records a person rejected for this author, by source" do
          decision(ResolveWikidata.name, "Q1")
          decision(ResolveViaf.name, "5391")
          decision(ResolveWikidata.name, "Q2", verdict: nil)
          decision(ResolveWikidata.name, "Q3", author: ::Books::Author.create!(name: "Someone Else"))
          decision("DataImporters::Books::Author::Finder", "Q4")

          rejected = RejectedRecords.new(@author)

          assert_equal [Set["Q1"], Set["5391"]], [rejected.ids(:wikidata), rejected.ids("viaf")]
          assert rejected.include?(:wikidata, "Q1")
          assert_not rejected.include?(:wikidata, "Q2")
        end

        test "an identifier is rejected when it names a rejected record of its source" do
          decision(ResolveWikidata.name, "Q1")
          rejected = RejectedRecords.new(@author)

          assert rejected.identifier?("books_author_wikidata_qid", "Q1")
          assert rejected.identifier?(:books_author_wikidata_qid, "Q1")
          assert_not rejected.identifier?("books_author_viaf", "Q1")
          assert_not rejected.identifier?("books_author_isni", "Q1")
        end

        test "a rejected decision that selected nothing rejects nothing" do
          decision(ResolveWikidata.name, nil, outcome: :unmatched)

          assert_equal Set.new, RejectedRecords.new(@author).ids(:wikidata)
        end

        test "a rejected Wikidata decision also bans the ids a merge redirected it from" do
          rejected = decision(ResolveWikidata.name, "Q10")
          @author.enrichments.create!(kind: EnrichFromWikidata::KIND, provider: "wikidata", outcome: :applied,
            match_decision: rejected,
            facts: {"wikidata_qid" => {"value" => "Q10", "applied" => true, "reason" => "filled", "redirected_from" => ["Q9"]}})
          other = decision(ResolveWikidata.name, "Q11", verdict: nil)
          @author.enrichments.create!(kind: EnrichFromWikidata::KIND, provider: "wikidata", outcome: :applied,
            match_decision: other,
            facts: {"wikidata_qid" => {"value" => "Q11", "applied" => true, "reason" => "filled", "redirected_from" => ["Q12"]}})

          rejected_records = RejectedRecords.new(@author)

          assert_equal Set["Q10", "Q9"], rejected_records.ids(:wikidata)
          assert rejected_records.identifier?("books_author_wikidata_qid", "Q9")
          assert_not rejected_records.identifier?("books_author_wikidata_qid", "Q12")
        end
      end
    end
  end
end
