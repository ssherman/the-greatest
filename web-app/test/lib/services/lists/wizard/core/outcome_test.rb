# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    module Wizard
      module Core
        class OutcomeTest < ActiveSupport::TestCase
          include ListWizardHelper

          setup do
            @row = wizard_row(wizard_list, position: 1, title: "War and Peace", authors: ["Leo Tolstoy"])
            @book = books_books(:war_and_peace)
          end

          def classify(**attributes)
            Outcome.classify(wizard_match(subject: @row, **attributes))
          end

          test "a certain identifier match is matched, pointing at the book" do
            result = classify(outcome: :matched, record: @book, confidence: :certain, decided_by: :identifier, candidates: [local_candidate(@book)])

            assert_equal ["matched", [], @book.id, nil], [result.bucket, result.reasons, result.target_record_id, result.external_key]
          end

          test "an AI match at high confidence passes through as matched" do
            result = classify(outcome: :matched, record: @book, confidence: :high, decided_by: :ai, candidates: [local_candidate(@book)])

            assert_equal "matched", result.bucket
          end

          test "a match at medium confidence (a failed source caps high at medium) is flagged unsure" do
            result = classify(outcome: :matched, record: @book, confidence: :medium, decided_by: :rule, candidates: [local_candidate(@book)])

            assert_equal ["flagged", ["unsure"]], [result.bucket, result.reasons]
          end

          test "a fallback is flagged unsure" do
            result = classify(outcome: :unmatched, confidence: :low, decided_by: :fallback, candidates: [local_candidate(@book)])

            assert_equal ["flagged", ["unsure"]], [result.bucket, result.reasons]
          end

          test "rule 5 (the service accepted a work nobody holds) is create, with that work" do
            work = ol_candidate("OL9W")
            result = classify(outcome: :unmatched, confidence: :high, decided_by: :rule, external: work, candidates: [work])

            assert_equal ["create", [], "OL9W"], [result.bucket, result.reasons, result.external_key]
          end

          test "no candidates at all is flagged not_found" do
            result = classify(outcome: :unmatched, confidence: :high, decided_by: :rule, candidates: [])

            assert_equal ["flagged", ["not_found"]], [result.bucket, result.reasons]
          end

          test "the AI picking none of the candidates is flagged not_found" do
            result = classify(outcome: :unmatched, confidence: :high, decided_by: :ai, candidates: [local_candidate(@book)])

            assert_equal ["flagged", ["not_found"]], [result.bucket, result.reasons]
          end

          test "the AI picking an Open Library work the service did not accept is flagged ai_only_pick, never create" do
            work = ol_candidate("OL3W", verdict: "abstain")
            result = classify(outcome: :unmatched, confidence: :high, decided_by: :ai, external: work, candidates: [work])

            assert_equal ["flagged", ["ai_only_pick"]], [result.bucket, result.reasons]
            assert_nil result.external_key
          end

          test "the AI picking the accepted work while local candidates exist is flagged unsure, not ai_only_pick" do
            work = ol_candidate("OL4W")
            result = classify(outcome: :unmatched, confidence: :high, decided_by: :ai, external: work,
              candidates: [local_candidate(@book), work])

            assert_equal ["flagged", ["unsure"]], [result.bucket, result.reasons]
          end

          test "a medium AI none carries both reasons" do
            result = classify(outcome: :unmatched, confidence: :medium, decided_by: :ai, candidates: [local_candidate(@book)])

            assert_equal ["unsure", "not_found"], result.reasons
          end
        end
      end
    end
  end
end
