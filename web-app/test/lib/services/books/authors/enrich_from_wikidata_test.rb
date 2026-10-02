# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class EnrichFromWikidataTest < ActiveSupport::TestCase
        TOLSTOY = {label: "Leo Tolstoy", born: 1828, died: 1910, enwiki: "Leo Tolstoy", identifiers: {viaf: ["96987389"]}}.freeze

        def setup
          @author = books_authors(:tolstoy)
          @author.identifiers.create!(identifier_type: :books_author_wikidata_qid, value: "Q7243")
          @wikidata = FakeWikidataClient.new(entities: {"Q7243" => wikidata_entity("Q7243", **TOLSTOY)})
          @lead = ::Wikipedia::Lead.new(language: "en", page_id: 18622119, title: "Leo Tolstoy", url: "https://en.wikipedia.org/wiki/Leo_Tolstoy",
            extract: "Count Lev…", wikibase_item: "Q7243", disambiguation: false, raw: "{}")
          @wikipedia = FakeWikipediaClient.new({["en", "Leo Tolstoy"] => @lead})
        end

        def enrich(refresh: false, wikipedia: @wikipedia, wikidata: @wikidata)
          EnrichFromWikidata.call(author: @author, refresh: refresh, client: wikidata, wikipedia_client: wikipedia)
        end

        def rows = @author.enrichments.for_kind(EnrichFromWikidata::KIND).order(:id)

        test "a match applies the item, links Wikipedia and writes one applied ledger row tied to the decision" do
          result = enrich

          row = rows.sole
          assert_equal [:matched, true], [result.data[:outcome], result.success?]
          assert_equal ["applied", "wikidata", true, "high"], [row.outcome, row.provider, row.recognized, row.confidence]
          assert_equal result.data[:decision], row.match_decision
          assert_equal "filled", row.facts.dig("viaf", "reason")
          assert_equal "linked", row.facts.dig("wikipedia", "reason")
          assert_includes row.citations, "https://www.wikidata.org/wiki/Q7243"
          assert_equal ["96987389"], @author.identifiers.where(identifier_type: :books_author_viaf).pluck(:value)
        end

        test "a miss writes an unrecognized row and deprecates the legacy Wikipedia description" do
          @author.identifiers.destroy_all
          legacy = @author.descriptions.create!(source: :wikipedia, content: "x", source_url: "https://en.wikipedia.org/wiki/Leo_Tolstoy")

          result = enrich(wikidata: FakeWikidataClient.new)

          assert_equal :unmatched, result.data[:outcome]
          assert_equal ["unrecognized", false], [rows.sole.outcome, rows.sole.recognized]
          assert legacy.reload.deprecated?
          assert_equal "deprecated", rows.sole.facts.dig("legacy_wikipedia", "reason")
        end

        test "a failed resolution writes a failed row and leaves legacy descriptions alone" do
          @author.identifiers.destroy_all
          legacy = @author.descriptions.create!(source: :wikipedia, content: "x", source_url: "https://en.wikipedia.org/wiki/Leo_Tolstoy")
          wikidata = FakeWikidataClient.new(searches: {"Leo Tolstoy" => ["Q7243"]}, entities: {"Q7243" => wikidata_entity("Q7243", **TOLSTOY)})
          task = mock("task")
          task.stubs(:call).returns(Services::Ai::Result.new(success: false, error: "timeout"))
          Services::Ai::Tasks::Matching::SelectExternalRecordTask.stubs(:new).returns(task)

          result = enrich(wikidata: wikidata)

          assert_equal [:failed, false], [result.data[:outcome], result.success?]
          assert_equal "failed", rows.sole.outcome
          assert legacy.reload.normal?
        end

        test "a Wikimedia error writes a failed row with the error" do
          wikidata = FakeWikidataClient.new
          wikidata.stubs(:entities).raises(::Wikimedia::Exceptions::HttpError.new("Wikimedia returned HTTP 503", 503))

          result = enrich(wikidata: wikidata)

          assert_equal "failed", rows.sole.outcome
          assert_match(/503/, rows.sole.error)
          assert_not result.success?
        end

        test "a failure after applying keeps the applied facts in the ledger" do
          limited = FakeWikipediaClient.new({["en", "Leo Tolstoy"] => ::Wikimedia::Exceptions::HttpError.new("Wikimedia returned HTTP 503", 503)})

          result = enrich(wikipedia: limited)

          row = rows.sole
          assert_equal "failed", row.outcome
          assert_equal "filled", row.facts.dig("viaf", "reason")
          assert_equal result.data[:decision], row.match_decision
        end

        test "a rate limit propagates and writes no row" do
          wikidata = FakeWikidataClient.new
          wikidata.stubs(:entities).raises(::Wikimedia::Exceptions::RateLimited.new("wait", retry_after: 30))

          assert_raises(::Wikimedia::Exceptions::RateLimited) { enrich(wikidata: wikidata) }
          assert_empty rows
        end

        test "an author already processed since its row was created is skipped without calling out" do
          enrich
          ResolveWikidata.expects(:call).never

          result = enrich

          assert_equal :skipped, result.data[:outcome]
          assert_equal ["applied", "skipped"], rows.map(&:outcome)
          assert_equal "already_processed", rows.last.reason
        end

        test "an unrecognized row newer than the author row counts as processed, guarding against re-running the AI" do
          @author.enrichments.create!(kind: EnrichFromWikidata::KIND, outcome: :unrecognized, reason: "no_match")
          ResolveWikidata.expects(:call).never

          result = enrich

          assert_equal :skipped, result.data[:outcome]
          assert_equal "already_processed", rows.last.reason
        end

        test "a failed or skipped run does not count as processed" do
          @author.enrichments.create!(kind: EnrichFromWikidata::KIND, outcome: :failed, error: "boom")
          @author.enrichments.create!(kind: EnrichFromWikidata::KIND, outcome: :skipped, reason: "placeholder")

          assert_equal :matched, enrich.data[:outcome]
        end

        test "a processed row older than the author row (a re-migrated author) does not count" do
          @author.enrichments.create!(kind: EnrichFromWikidata::KIND, outcome: :applied, created_at: 2.days.ago)
          @author.update_columns(created_at: 1.day.ago)

          assert_equal :matched, enrich.data[:outcome]
        end

        test "refresh runs even when processed" do
          enrich

          assert_equal :matched, enrich(refresh: true).data[:outcome]
        end

        test "a placeholder author is skipped" do
          placeholder = books_authors(:excluded_placeholder)

          result = EnrichFromWikidata.call(author: placeholder, client: FakeWikidataClient.new)

          assert_equal [:skipped, "placeholder"], [result.data[:outcome], result.data[:enrichment].reason]
        end

        test "an author holding a different Wikidata id: nothing applied, the decision flagged for review" do
          @author.identifiers.create!(identifier_type: :books_author_wikidata_qid, value: "Q1")
          wikidata = FakeWikidataClient.new(entities: {
            "Q7243" => wikidata_entity("Q7243", **TOLSTOY),
            "Q1" => wikidata_entity("Q1", label: "Somebody Else", born: 1700)
          })

          result = enrich(wikidata: wikidata)

          assert_equal ["nothing_to_apply", "held_qid_conflict"], [rows.sole.outcome, rows.sole.reason]
          assert result.data[:decision].reload.needs_review
          assert_empty @author.identifiers.where(identifier_type: :books_author_viaf)
        end

        test "a rate limit after the facts were saved: the rescheduled run finishes without duplicating anything" do
          russian = ::Books::Country.create!(name: "Russian Runner Test")
          lookup_result = ::Services::Books::CountryLookup::Result.new(countries: [russian], unmatched: [])
          ::Services::Books::CountryLookup.any_instance.stubs(:from_wikidata).returns(lookup_result)
          @wikidata = FakeWikidataClient.new(entities: {"Q7243" => wikidata_entity("Q7243", **TOLSTOY, citizenships: ["Q34266"])})
          limited = FakeWikipediaClient.new({["en", "Leo Tolstoy"] => ::Wikimedia::Exceptions::RateLimited.new("wait", retry_after: 30)})

          assert_raises(::Wikimedia::Exceptions::RateLimited) { enrich(wikipedia: limited) }

          first = rows.sole
          assert_equal ["failed", "rate_limited"], [first.outcome, first.reason]
          assert_equal "filled", first.facts.dig("viaf", "reason")
          assert_not_nil first.match_decision

          identifiers = @author.identifiers.count
          enrich

          assert_equal identifiers, @author.identifiers.count
          assert_equal 1, @author.author_countries.count
          assert_equal 1, @author.external_links.where(source: :wikipedia).count
          # The second run wrote its own row: it found everything already
          # set except the link.
          second = rows.order(:id).last
          assert_equal "linked", second.facts.dig("wikipedia", "reason")
          assert_equal "already_set", second.facts.dig("viaf", "reason")
        end

        test "a run whose decision a person rejected does not count as processed" do
          decision = ::MatchDecision.create!(finder: ResolveWikidata.name, subject: @author, outcome: :matched, confidence: :high,
            decided_by: :rule, verdict: :rejected, candidates: [{"external_key" => "Q1"}], selected_index: 1)
          @author.enrichments.create!(kind: EnrichFromWikidata::KIND, outcome: :applied, reason: "matched Q1", match_decision: decision)

          result = EnrichFromWikidata.call(author: @author, client: FakeWikidataClient.new)

          assert_equal :unmatched, result.data[:outcome]
          assert_equal "no_match", result.data[:enrichment].reason
        end

        test "a held id Wikidata has merged into the matched item applies normally" do
          @author.identifiers.destroy_all
          @author.identifiers.create!(identifier_type: :books_author_wikidata_qid, value: "Q999")
          wikidata = FakeWikidataClient.new(entities: {"Q999" => wikidata_entity("Q7243", **TOLSTOY)})

          enrich(wikidata: wikidata)

          assert_equal "applied", rows.sole.outcome
          assert_equal ["Q7243", "Q999"], @author.identifiers.where(identifier_type: :books_author_wikidata_qid).pluck(:value).sort
        end

        test "a later match restores a legacy description an earlier miss deprecated" do
          @author.identifiers.destroy_all
          legacy = @author.descriptions.create!(source: :wikipedia, content: "x", source_url: "https://en.wikipedia.org/wiki/Leo_Tolstoy")
          enrich(wikidata: FakeWikidataClient.new)
          assert legacy.reload.deprecated?

          @author.identifiers.create!(identifier_type: :books_author_wikidata_qid, value: "Q7243")
          enrich(refresh: true)

          assert legacy.reload.normal?
          assert_equal "restored", rows.last.facts.dig("legacy_wikipedia", "reason")
        end

        test "a re-migrated author gets back the Wikidata id its earlier match chose, and resolves without searching" do
          @author.identifiers.destroy_all
          decision = ::MatchDecision.create!(finder: ResolveWikidata.name, subject: @author, outcome: :matched, confidence: :high,
            decided_by: :ai, candidates: [{"external_source" => "wikidata", "external_key" => "Q7243"}], selected_index: 1,
            created_at: @author.created_at - 1.day)

          result = enrich

          assert_equal ["identifier", "certain"], [result.data[:decision].decided_by, result.data[:decision].confidence]
          assert_not @wikidata.called?(:search)
          assert_equal ["Q7243", decision.id], rows.sole.facts["restored_identifier"].values_at("value", "decision_id")
        end

        test "a rate limit before the decision takes a restored id back off, so the rescheduled run restores and records it" do
          @author.identifiers.destroy_all
          ::MatchDecision.create!(finder: ResolveWikidata.name, subject: @author, outcome: :matched, confidence: :high,
            decided_by: :ai, candidates: [{"external_source" => "wikidata", "external_key" => "Q7243"}], selected_index: 1,
            created_at: @author.created_at - 1.day)
          limited = FakeWikidataClient.new
          limited.stubs(:entities).raises(::Wikimedia::Exceptions::RateLimited.new("wait", retry_after: 30))

          assert_raises(::Wikimedia::Exceptions::RateLimited) { enrich(wikidata: limited) }
          assert_empty @author.identifiers.where(identifier_type: :books_author_wikidata_qid)
          assert_empty rows

          enrich

          assert_equal "Q7243", rows.sole.facts.dig("restored_identifier", "value")
        end

        test "an unexpected error after the decision writes one failed row tied to it, and does not raise" do
          ApplyWikidata.stubs(:call).raises(RuntimeError, "boom")

          result = enrich

          row = rows.sole
          assert_equal [:failed, false], [result.data[:outcome], result.success?]
          assert_equal ["failed", "unexpected_error", "RuntimeError: boom"], [row.outcome, row.reason, row.error]
          assert_equal result.data[:decision], row.match_decision
          assert result.data[:decision].persisted?
        end

        test "an unexpected error logs the full message with backtrace" do
          ApplyWikidata.stubs(:call).raises(RuntimeError, "boom")
          Rails.logger.expects(:error).with { |message| message.include?("RuntimeError") && message.include?("boom") && message.lines.size > 1 }

          enrich
        end
      end
    end
  end
end
