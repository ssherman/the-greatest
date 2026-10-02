# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class RejectExternalLinkTest < ActiveSupport::TestCase
        URL = "https://en.wikipedia.org/wiki/Reject_Link_Author"

        def setup
          @author = ::Books::Author.create!(name: "Reject Link Author")
          @user = users(:admin_user)
        end

        def decision(finder, key, outcome: :matched, created_at: Time.current)
          ::MatchDecision.create!(
            finder: finder, subject: @author, outcome: outcome, confidence: :medium, decided_by: :ai, needs_review: true,
            candidates: [{"external_source" => "x", "external_key" => key}], selected_index: (outcome == :matched) ? 1 : nil,
            created_at: created_at
          )
        end

        def ledger(kind, decision, facts)
          @author.enrichments.create!(kind: kind, provider: "test", outcome: :applied, reason: "matched", facts: facts,
            match_decision: decision)
        end

        def ai_run(sources:, facts: {})
          @author.enrichments.create!(kind: EnrichAuthor::KIND, outcome: :applied,
            facts: facts.merge("sources" => {"value" => sources, "applied" => false, "reason" => "input"}))
        end

        def filled(value, **extra) = {"value" => value, "applied" => true, "reason" => "filled"}.merge(extra.stringify_keys)

        def hold(type, value) = @author.identifiers.create!(identifier_type: type, value: value)

        def expect_rerun(times: 1)
          ::Books::Authors::WikidataJob.expects(:perform_async).with(@author.id, true).times(times)
        end

        def reject(target) = RejectExternalLink.call(decision: target, user: @user)

        test "reverts what the run applied, removes the record's own id and link, rejects and reviews, and runs Wikidata again" do
          wikidata = decision(ResolveWikidata.name, "Q1")
          hold(:books_author_wikidata_qid, "Q1")
          hold(:books_author_isni, "0000000121")
          @author.update!(birth_year: 1901)
          @author.external_links.create!(url: URL, name: "Wikipedia", source: :wikipedia, link_category: :information)
          ledger(EnrichFromWikidata::KIND, wikidata, "wikidata_qid" => filled("Q1"), "isni" => filled("0000000121"),
            "birth_year" => filled(1901), "wikipedia" => {"value" => URL, "applied" => true, "reason" => "linked"})
          expect_rerun

          result = reject(wikidata)

          assert result.success?
          @author.reload
          assert_not @author.identifiers.exists?
          assert_nil @author.birth_year
          assert_not @author.external_links.exists?
          wikidata.reload
          assert wikidata.verdict_rejected?
          assert_equal [@user, "Link rejected."], [wikidata.reviewed_by, wikidata.review_note]
          assert_equal [wikidata], result.data[:decisions]
          assert_includes result.data[:reverted], "birth_year"
        end

        test "a run that applied nothing loses only the record's own id and its Wikipedia link" do
          wikidata = decision(ResolveWikidata.name, "Q1")
          hold(:books_author_wikidata_qid, "Q1")
          hold(:books_author_isni, "0000000121")
          @author.update!(birth_year: 1901)
          @author.external_links.create!(url: URL, name: "Wikipedia", source: :wikipedia, link_category: :information)
          already = ->(value) { {"value" => value, "applied" => false, "reason" => "already_set"} }
          ledger(EnrichFromWikidata::KIND, wikidata, "wikidata_qid" => already.call("Q1"), "isni" => already.call("0000000121"),
            "birth_year" => already.call(1901), "wikipedia" => already.call(URL))
          expect_rerun

          reject(wikidata)

          @author.reload
          assert_equal [["books_author_isni", "0000000121"]], @author.identifiers.pluck(:identifier_type, :value)
          assert_equal 1901, @author.birth_year
          assert_not @author.external_links.exists?
        end

        test "a value a person changed after the run stays" do
          viaf = decision(ResolveViaf.name, "5391")
          @author.update!(birth_year: 1950)
          ledger(EnrichFromViaf::KIND, viaf, "birth_year" => filled(1948))
          expect_rerun

          reject(viaf)

          assert_equal 1950, @author.reload.birth_year
        end

        test "every decision of the same finder that selected the record is rejected with it" do
          first = decision(ResolveWikidata.name, "Q1", created_at: 2.days.ago)
          second = decision(ResolveWikidata.name, "Q1")
          other = decision(ResolveWikidata.name, "Q2")
          expect_rerun

          result = reject(second)

          assert_equal [second, first], result.data[:decisions]
          assert first.reload.verdict_rejected?
          assert_nil other.reload.verdict
        end

        test "a rejected VIAF run takes every Wikidata decision its stamped id led to, however old" do
          viaf = decision(ResolveViaf.name, "5391", created_at: 1.hour.ago)
          ledger(EnrichFromViaf::KIND, viaf, "wikidata_qid" => filled("Q9"), "viaf" => filled("5391"))
          earlier = decision(ResolveWikidata.name, "Q9", created_at: 2.hours.ago)
          follow_up = decision(ResolveWikidata.name, "Q9")
          @author.update!(death_year: 2013)
          ledger(EnrichFromWikidata::KIND, follow_up, "wikidata_qid" => {"value" => "Q9", "applied" => false, "reason" => "already_set"},
            "death_year" => filled(2013))
          hold(:books_author_wikidata_qid, "Q9")
          hold(:books_author_viaf, "5391")
          expect_rerun

          result = reject(viaf)

          assert_equal [viaf, earlier, follow_up], result.data[:decisions]
          assert earlier.reload.verdict_rejected?
          assert follow_up.reload.verdict_rejected?
          @author.reload
          assert_not @author.identifiers.exists?
          assert_nil @author.death_year
        end

        test "a redirected Wikidata id is removed along with the canonical one" do
          wikidata = decision(ResolveWikidata.name, "Q2")
          hold(:books_author_wikidata_qid, "Q2")
          hold(:books_author_wikidata_qid, "Q1")
          hold(:books_author_isni, "0000000121")
          ledger(EnrichFromWikidata::KIND, wikidata, "wikidata_qid" => filled("Q2", redirected_from: ["Q1"]))
          expect_rerun

          reject(wikidata)

          assert_equal [["books_author_isni", "0000000121"]], @author.reload.identifiers.pluck(:identifier_type, :value)
        end

        test "a VIAF reject takes a Wikidata decision reached through a Wikidata redirect" do
          viaf = decision(ResolveViaf.name, "5391")
          ledger(EnrichFromViaf::KIND, viaf, "wikidata_qid" => filled("Q9"), "viaf" => filled("5391"))
          redirected = decision(ResolveWikidata.name, "Q10")
          ledger(EnrichFromWikidata::KIND, redirected, "wikidata_qid" => filled("Q10", redirected_from: ["Q9"]))
          unrelated = decision(ResolveWikidata.name, "Q11")
          expect_rerun

          result = reject(viaf)

          assert_equal [viaf, redirected], result.data[:decisions]
          assert redirected.reload.verdict_rejected?
          assert_nil unrelated.reload.verdict
        end

        test "a redirected Wikidata reject also rejects an older decision keyed the pre-merge id" do
          old = decision(ResolveWikidata.name, "Q1", created_at: 1.day.ago)
          @author.update!(birth_year: 1920)
          ledger(EnrichFromWikidata::KIND, old, "birth_year" => filled(1920))
          wikidata = decision(ResolveWikidata.name, "Q2")
          ledger(EnrichFromWikidata::KIND, wikidata, "wikidata_qid" => filled("Q2", redirected_from: ["Q1"]))
          unrelated = decision(ResolveWikidata.name, "Q3")
          expect_rerun

          result = reject(wikidata)

          assert_equal [wikidata, old], result.data[:decisions]
          assert old.reload.verdict_rejected?
          assert_nil @author.reload.birth_year
          assert_nil unrelated.reload.verdict
        end

        test "a VIAF cascade sweeps in another decision sharing the redirected follow-up's key" do
          viaf = decision(ResolveViaf.name, "5391")
          ledger(EnrichFromViaf::KIND, viaf, "wikidata_qid" => filled("Q9"), "viaf" => filled("5391"))
          redirected = decision(ResolveWikidata.name, "Q10", created_at: 1.hour.ago)
          ledger(EnrichFromWikidata::KIND, redirected, "wikidata_qid" => filled("Q10", redirected_from: ["Q9"]))
          conflict = decision(ResolveWikidata.name, "Q10")
          ledger(EnrichFromWikidata::KIND, conflict, "wikidata_qid" => {"value" => "Q10", "applied" => false, "reason" => "held_qid_conflict"})
          expect_rerun

          result = reject(viaf)

          assert_includes result.data[:decisions], conflict
          assert conflict.reload.verdict_rejected?
        end

        test "an AI run that used the record is reverted and its description deprecated; one that did not is left alone" do
          wikidata = decision(ResolveWikidata.name, "Q1")
          @author.update!(gender: :female, death_year: 1980)
          @author.assign_description(source: :ai_generated, content: "Written from Q1.")
          @author.save!
          ai_run(sources: [], facts: {"death_year" => filled(1980)})
          ai_run(sources: [{"source" => "wikidata", "source_id" => "Q1"}],
            facts: {"gender" => filled("female"), "description" => filled("Written from Q1.")})
          expect_rerun

          result = reject(wikidata)

          @author.reload
          assert_equal [nil, 1980], [@author.gender, @author.death_year]
          assert_equal "deprecated", @author.descriptions.sole.rank
          assert_equal 1, result.data[:descriptions_deprecated]
        end

        test "an AI description written by a run that did not use the record stays" do
          wikidata = decision(ResolveWikidata.name, "Q1")
          @author.assign_description(source: :ai_generated, content: "Written without Q1.")
          @author.save!
          ai_run(sources: [{"source" => "wikidata", "source_id" => "Q1"}], facts: {"description" => {"value" => "x", "applied" => false, "reason" => "already_set"}})
          ai_run(sources: [], facts: {"description" => filled("Written without Q1.")})
          expect_rerun

          reject(wikidata)

          assert_equal "normal", @author.descriptions.reload.sole.rank
        end

        test "a decision with no ledger row is still rejected and its record's id removed" do
          wikidata = decision(ResolveWikidata.name, "Q1")
          hold(:books_author_wikidata_qid, "Q1")
          expect_rerun

          assert reject(wikidata).success?

          assert wikidata.reload.verdict_rejected?
          assert_not @author.identifiers.exists?
        end

        test "refuses an unmatched decision, a finder's decision, and one already rejected, changing and queuing nothing" do
          ::Books::Authors::WikidataJob.expects(:perform_async).never
          unmatched = decision(ResolveWikidata.name, nil, outcome: :unmatched)
          finder = decision("DataImporters::Books::Author::Finder", "Q1")
          rejected = decision(ResolveWikidata.name, "Q1")
          rejected.update!(verdict: :rejected)

          [unmatched, finder, rejected].each do |target|
            result = reject(target)
            assert_not result.success?
            assert_equal 1, result.errors.size
          end
          assert_nil unmatched.reload.verdict
          assert_nil finder.reload.verdict
        end

        test "a second reject of the same decision is refused and queues nothing more" do
          wikidata = decision(ResolveWikidata.name, "Q1")
          stale = ::MatchDecision.find(wikidata.id)
          expect_rerun(times: 1)

          assert reject(wikidata).success?
          assert_not reject(stale).success?
        end
      end
    end
  end
end
