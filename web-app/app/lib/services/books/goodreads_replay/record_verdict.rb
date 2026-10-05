# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      # The only way a replay finding reaches the ledger (Goodreads import spec
      # §12.7). Every replay pass re-derives its findings, so most findings are
      # recorded again on each pass:
      # - a verdict an admin rejected suppresses its finding;
      # - one an admin approved is kept exactly as approved;
      # - an unreviewed one takes the newest evidence.
      # auto: a rule-certain (or, for authors, AI-checked) finding is approved
      # on its own; the rest are proposed for the admin queue.
      class RecordVerdict
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(kind:, subject_key:, payload:, decided_by:, confidence: nil, reason: nil, ai_chat_id: nil, auto: false)
          new(kind: kind, subject_key: subject_key, payload: payload, decided_by: decided_by, confidence: confidence,
            reason: reason, ai_chat_id: ai_chat_id, auto: auto).call
        end

        def initialize(kind:, subject_key:, payload:, decided_by:, confidence:, reason:, ai_chat_id:, auto:)
          @kind = kind
          @subject_key = subject_key
          @attributes = {payload: payload.deep_stringify_keys, decided_by: decided_by, confidence: confidence,
                         reason: reason, ai_chat_id: ai_chat_id, status: auto ? :approved : :proposed}
        end

        def call
          verdict = ::Books::RepairVerdict.find_or_initialize_by(kind: @kind, subject_key: @subject_key)
          return done(verdict, :suppressed) if verdict.rejected?
          return done(verdict, :kept) if verdict.reviewed?

          created = verdict.new_record?
          verdict.update!(@attributes)
          done(verdict, created ? :created : :updated)
        rescue ActiveRecord::RecordNotUnique
          # Two jobs recorded the same finding at once; the second reads the first's row.
          retry
        end

        private

        def done(verdict, outcome)
          Result.new(success?: true, data: {verdict: verdict, outcome: outcome}, errors: [])
        end
      end
    end
  end
end
