# frozen_string_literal: true

module Services
  module Books
    module RepairVerdicts
      # The repair-verdict queue's filters, shared by the admin page and the admin API so the two cannot drift. A value
      # outside a vocabulary is ignored here (the API rejects bad values with a 400 before calling this). Superseded
      # verdicts (replay proposals the Goodreads rebuild retired) are never in the default scope. Status is applied by
      # each caller.
      class Filter
        KINDS = ::Books::RepairVerdict.kinds.keys.freeze
        STATUSES = ::Books::RepairVerdict.statuses.keys.freeze
        DECIDED_BY = ::Books::RepairVerdict.decided_bies.keys.freeze
        CONFIDENCES = ::Books::RepairVerdict.confidences.keys.freeze

        def self.call(scope = ::Books::RepairVerdict.current, kind: nil, decided_by: nil, confidence: nil, guess: nil)
          scope = scope.where(kind: kind) if KINDS.include?(kind.to_s)
          scope = scope.where(decided_by: decided_by) if DECIDED_BY.include?(decided_by.to_s)
          scope = scope.where(confidence: confidence) if CONFIDENCES.include?(confidence.to_s)
          scope = scope.where("payload->>'guess' = 'true'") if guess.to_s == "true"
          scope
        end
      end
    end
  end
end
