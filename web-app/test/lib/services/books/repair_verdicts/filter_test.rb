# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module RepairVerdicts
      class FilterTest < ActiveSupport::TestCase
        def verdict(key, kind: :relink, decided_by: :rule, confidence: :certain, payload: {}, **attrs)
          ::Books::RepairVerdict.create!(kind: kind, subject_key: key, decided_by: decided_by, confidence: confidence,
            payload: payload, reason: "test", **attrs)
        end

        def call(**args) = Filter.call(kind: nil, decided_by: nil, confidence: nil, guess: nil, **args)

        setup do
          @relink = verdict("f:1", decided_by: :ai, confidence: :high)
          @merge = verdict("f:2", kind: :merge_books, confidence: :low)
          @guess = verdict("f:3", kind: :reimport_guess, payload: {"guess" => true})
          @superseded = verdict("f:4", superseded_at: Time.current)
        end

        test "with no filters it returns current verdicts, never superseded ones" do
          assert_equal [@relink, @merge, @guess].map(&:id).sort, call.pluck(:id).sort
        end

        test "filters by kind, decider and confidence" do
          assert_equal [@merge.id], call(kind: "merge_books").pluck(:id)
          assert_equal [@relink.id], call(decided_by: "ai").pluck(:id)
          assert_equal [@relink.id], call(confidence: "high").pluck(:id)
          assert_empty call(kind: "relink", confidence: "low")
        end

        test "guess true keeps only guesses" do
          assert_equal [@guess.id], call(guess: "true").pluck(:id)
          assert_equal [@guess.id], call(guess: true).pluck(:id)
          assert_equal 3, call(guess: "false").count
        end

        test "values outside the vocabulary are ignored" do
          assert_equal 3, call(kind: "bogus", decided_by: "nobody", confidence: "meh").count
        end

        test "it narrows a given scope" do
          scope = ::Books::RepairVerdict.current.where(kind: :relink)

          assert_equal [@relink.id], Filter.call(scope, kind: nil, decided_by: nil, confidence: nil, guess: nil).pluck(:id)
        end

        test "exposes the vocabularies" do
          assert_includes Filter::KINDS, "relink"
          assert_equal %w[proposed approved rejected], Filter::STATUSES
          assert_includes Filter::DECIDED_BY, "ai"
          assert_includes Filter::CONFIDENCES, "certain"
        end
      end
    end
  end
end
