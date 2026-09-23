# frozen_string_literal: true

module DataImporters
  # The outcome the rules or the AI settled on, before it is recorded.
  # `duplicate_pairs` is a list of [record_a, record_b, source_symbol] the
  # finder turns into DuplicateCandidate rows.
  Decision = Struct.new(
    :outcome, :record, :confidence, :decided_by, :reason,
    :external, :selected_index, :duplicate_pairs,
    keyword_init: true
  ) do
    def initialize(**attributes)
      super
      self.duplicate_pairs ||= []
    end

    def self.fallback(reason)
      new(outcome: :unmatched, record: nil, confidence: :low, decided_by: :fallback, reason: reason)
    end
  end
end
