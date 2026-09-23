# frozen_string_literal: true

module DataImporters
  # One thing a finder considered: a local record, an external record, or
  # both once an external key turns out to be held locally. `sources` names
  # every source that reached it; `scores` is per source; `evidence` is a
  # JSON-safe hash the rules and the AI prompt read (title, creators, year,
  # ranked_position, identifiers, external_verdict, ...).
  Candidate = Struct.new(
    :record, :external_key, :external_source, :external_record,
    :sources, :scores, :evidence, :decisive,
    keyword_init: true
  ) do
    def initialize(**attributes)
      super
      self.sources ||= []
      self.scores ||= {}
      self.evidence ||= {}
      self.decisive = false if decisive.nil?
    end

    def local?
      !record.nil?
    end

    def external?
      !external_key.nil?
    end

    def decisive?
      decisive == true
    end

    def ranked?
      evidence[:ranked_position].present?
    end

    def external_verdict
      evidence[:external_verdict]
    end

    def external_accepted?
      external_verdict == "accept"
    end

    # Fold another candidate for the same thing into this one. A present
    # value is never overwritten by an absent one.
    def absorb(other)
      self.record ||= other.record
      self.external_key ||= other.external_key
      self.external_source ||= other.external_source
      self.external_record ||= other.external_record
      self.sources = sources | other.sources
      # Two halves of one candidate from the same source (a book holding keys
      # for two works both returned by one resolve) keep the better score.
      self.scores = scores.merge(other.scores) { |_source, mine, theirs| [mine, theirs].compact.max }
      self.evidence = evidence.merge(other.evidence) { |_key, mine, theirs| mine.nil? ? theirs : mine }
      self.decisive = decisive? || other.decisive?
      self
    end

    # The JSON stored on match_decisions.candidates: ids and evidence only,
    # never the record or the external payload.
    def snapshot
      {
        record_type: record&.class&.name,
        record_id: record&.id,
        external_source: external_source&.to_s,
        external_key: external_key,
        sources: sources.map(&:to_s),
        scores: scores.deep_stringify_keys,
        evidence: evidence.deep_stringify_keys
      }
    end
  end
end
