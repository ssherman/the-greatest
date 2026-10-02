# frozen_string_literal: true

module DataImporters
  # What a finder returns: the decision, the record it names (nil when
  # unmatched), how sure it is, who decided, why, and what it considered.
  # `external` is the best external candidate to hydrate from when
  # unmatched; `external_resolution` is a whole external response a source
  # kept for the provider (books: the Open Library Resolution); `decision`
  # is the persisted MatchDecision.
  Match = Struct.new(
    :outcome, :record, :confidence, :decided_by, :reason, :candidates,
    :external, :external_resolution, :decision, :sources_failed,
    keyword_init: true
  ) do
    def initialize(**attributes)
      super
      self.candidates ||= []
      self.sources_failed ||= []
    end

    def matched?
      outcome == :matched
    end

    def unmatched?
      outcome == :unmatched
    end

    def needs_review?
      %i[medium low].include?(confidence) || decided_by == :fallback
    end
  end
end
