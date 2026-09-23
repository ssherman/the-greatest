# frozen_string_literal: true

module DataImporters
  # The deterministic stage of FinderBase#call. Returns a Decision, or nil
  # when the AI has to decide. The first rule that applies wins; rules 0-2
  # are the early exits and never fire under `verify`.
  class Decider
    def initialize(finder:, query:, candidates:, verify:, sources_run: 0)
      @finder = finder
      @query = query
      @candidates = candidates
      @verify = verify
      @sources_run = sources_run
    end

    def call
      unless @verify
        decision = legacy_decision || identifier_decision || external_accept_decision
        return decision if decision
      end

      return no_candidates_decision if @candidates.empty?

      exact_decision || external_only_accept_decision
    end

    private

    # Rule 0 (increment 1 only): the pre-redesign lookup found it.
    def legacy_decision
      candidate = @candidates.find { |c| c.local? && c.sources.include?(:legacy) }
      return nil unless candidate

      matched(candidate.record, :certain, :rule, "legacy lookup found #{label(candidate)}")
    end

    # Rule 1: a corroborated identifier hit. Several: prefer ranked, then
    # most lists, then oldest; the rest are identifier collisions.
    def identifier_decision
      hits = @candidates.select { |c| c.local? && c.sources.include?(:identifier) && @finder.corroborated?(@query, c) }
      return nil if hits.empty?

      chosen, *rest = preferred(hits)
      identifier = chosen.evidence[:matched_identifier] || {}
      pairs = rest.map { |c| [chosen.record, c.record, :identifier_collision] }
      matched(
        chosen.record, :certain, :identifier,
        "identifier #{identifier[:type]} #{identifier[:value]} held by #{label(chosen)}",
        external: (chosen.external? ? chosen : nil), duplicate_pairs: pairs
      )
    end

    # Rule 2: the external source accepted a key a local record holds.
    # Several local records holding it: prefer ranked, then most lists, then
    # oldest; the rest are external-key collisions.
    def external_accept_decision
      hits = @candidates.select { |c| c.local? && c.external_accepted? && @finder.corroborated?(@query, c) }
      return nil if hits.empty?

      chosen, *rest = preferred(hits)
      pairs = rest.map { |c| [chosen.record, c.record, :external_key_collision] }
      matched(
        chosen.record, :certain, :identifier,
        "#{chosen.external_source} accepted #{chosen.external_key}, held by #{label(chosen)}",
        external: chosen, duplicate_pairs: pairs
      )
    end

    # Rule 3.
    def no_candidates_decision
      Decision.new(outcome: :unmatched, record: nil, confidence: :high, decided_by: :rule,
        reason: "no candidates from #{@sources_run} sources")
    end

    # Rule 4.
    def exact_decision
      locals = @candidates.select(&:local?)
      return nil unless locals.size == 1 && @finder.exact_match?(@query, locals.first)

      candidate = locals.first
      matched(candidate.record, :high, :rule, "exact title and creator match on #{label(candidate)}",
        external: (candidate.external? ? candidate : nil))
    end

    # Rule 5.
    def external_only_accept_decision
      return nil if @candidates.any?(&:local?)

      accepted = @candidates.find(&:external_accepted?)
      return nil unless accepted

      Decision.new(outcome: :unmatched, record: nil, confidence: :high, decided_by: :rule,
        reason: "#{accepted.external_source} accepted #{accepted.external_key}; nobody holds it locally",
        external: accepted)
    end

    def preferred(candidates)
      candidates.sort_by do |c|
        [@finder.ranked?(c.record) ? 0 : 1, -@finder.list_count(c.record), c.record.id]
      end
    end

    def matched(record, confidence, decided_by, reason, external: nil, duplicate_pairs: [])
      Decision.new(outcome: :matched, record: record, confidence: confidence, decided_by: decided_by,
        reason: reason, external: external, duplicate_pairs: duplicate_pairs)
    end

    def label(candidate)
      "#{candidate.record.class.name}##{candidate.record.id}"
    end
  end
end
