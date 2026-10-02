# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class RestoreIdentifierTest < ActiveSupport::TestCase
        QID = "books_author_wikidata_qid"

        def setup
          @author = ::Books::Author.create!(name: "Restored Author")
        end

        def decide(key, finder: ResolveWikidata, outcome: :matched, at: @author.created_at - 1.day, **attributes)
          ::MatchDecision.create!(finder: finder.name, subject: @author, outcome: outcome, confidence: :high, decided_by: :ai,
            candidates: [{"external_key" => key}], selected_index: (outcome == :matched) ? 1 : nil, created_at: at, **attributes)
        end

        def restore(finder = ResolveWikidata) = RestoreIdentifier.call(author: @author, finder: finder)

        def held(type = QID) = @author.identifiers.where(identifier_type: type).pluck(:value)

        test "puts back the id the latest earlier-era match chose, and returns the fact" do
          decide("Q1", at: @author.created_at - 2.days)
          decision = decide("Q7243")

          assert_equal({"value" => "Q7243", "applied" => true, "reason" => "earlier_decision", "decision_id" => decision.id}, restore)
          assert_equal ["Q7243"], held
        end

        test "a VIAF decision puts back the VIAF id" do
          decide("5391", finder: ResolveViaf)

          assert_equal "5391", restore(ResolveViaf)["value"]
          assert_equal ["5391"], held("books_author_viaf")
        end

        test "a decision from this era, even one that matched nothing, stops an older match coming back" do
          decide("Q7243")
          decide(nil, outcome: :unmatched, at: @author.created_at + 1.minute)

          assert_nil restore
          assert_empty held
        end

        test "a rejected latest decision puts nothing back, even with an older match behind it" do
          decide("Q1", at: @author.created_at - 2.days)
          decide("Q7243", verdict: :rejected)

          assert_nil restore
          assert_empty held
        end

        test "an id rejected through another decision is not put back" do
          decide("Q7243", at: @author.created_at - 2.days, verdict: :rejected)
          decide("Q7243")

          assert_nil restore
        end

        test "a decision flagged for review comes back only once a person reviewed it" do
          decision = decide("Q7243", needs_review: true)
          assert_nil restore

          decision.update!(reviewed_at: Time.current)
          assert_equal "Q7243", restore["value"]
        end

        test "an author already holding an id of that type, or an id another author holds, gets nothing" do
          decide("Q7243")
          other = ::Books::Author.create!(name: "Holder")
          other.identifiers.create!(identifier_type: QID, value: "Q7243")
          assert_nil restore

          other.identifiers.destroy_all
          @author.identifiers.create!(identifier_type: QID, value: "Q9")
          assert_nil restore
          assert_equal ["Q9"], held
        end
      end
    end
  end
end
