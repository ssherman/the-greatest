# frozen_string_literal: true

module Books
  module OpenLibrary
    # The full response of a `POST /resolve` call. `decision` is the only
    # authoritative verdict; `candidates` is never re-sorted here -- the
    # server's rank order is the contract (a `/resolve` call's `limit` has
    # already done any truncating server-side).
    #
    # Subclassing `Data.define(...)` (rather than passing it a block) so
    # Decision can be a real nested constant -- Standard's
    # Lint/ConstantDefinitionInBlock rejects a constant assigned inside a
    # `Data.define do ... end` block.
    class Resolution < Data.define(:decision, :candidates, :guards_tripped, :volume_guards_tripped, :source_version)
      Decision = Data.define(:verdict, :key, :score, :margin, :reason)

      def self.from_response(envelope)
        data = envelope["data"]
        source_version = envelope["source_version"]
        decision_hash = data["decision"]

        new(
          decision: Decision.new(
            verdict: decision_hash["verdict"],
            key: decision_hash.dig("key", "key"),
            score: decision_hash["score"],
            margin: decision_hash["margin"],
            reason: decision_hash["reason"]
          ),
          candidates: (data["candidates"] || []).map { |candidate| Candidate.from_record(candidate, source_version: source_version) },
          guards_tripped: data["guards_tripped"] || [],
          volume_guards_tripped: data["volume_guards_tripped"] || [],
          source_version: source_version&.deep_symbolize_keys
        )
      end

      def accept?
        decision.verdict == "accept"
      end

      def abstain?
        decision.verdict == "abstain"
      end

      def reject?
        decision.verdict == "reject"
      end

      # The accepted candidate's full record, or nil when the decision isn't
      # an accept -- never re-decided from the candidate list itself.
      def accepted
        return nil unless accept?

        candidates.find { |candidate| candidate.work_key == decision.key }
      end
    end
  end
end
