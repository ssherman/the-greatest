# frozen_string_literal: true

module Services
  module Books
    module Authors
      # The external records a person rejected for one author (spec §12): the
      # candidate each rejected Wikidata or VIAF decision selected, plus, for
      # a rejected Wikidata decision, every id a Wikidata merge recorded as
      # `redirected_from` on its ledger rows -- a merge gave the same item
      # another id along the way, so a later run naming that other id is
      # naming the same rejected record. The resolvers never consider a
      # banned id again, and FactSheet#stamp never puts one back on the
      # author. Two queries (the decisions, then their ledger rows), on first
      # use.
      class RejectedRecords
        FINDERS = {
          "Services::Books::Authors::ResolveWikidata" => "wikidata",
          "Services::Books::Authors::ResolveViaf" => "viaf"
        }.freeze
        IDENTIFIER_SOURCES = {
          "books_author_wikidata_qid" => "wikidata",
          "books_author_viaf" => "viaf"
        }.freeze

        def initialize(author)
          @author = author
        end

        # External keys ("Q42", "96987389").
        def ids(source) = by_source.fetch(source.to_s, Set.new)

        def include?(source, key) = ids(source).include?(key.to_s)

        # Whether stamping this identifier would bring a rejected record back.
        def identifier?(type, value)
          source = IDENTIFIER_SOURCES[type.to_s]
          source.present? && include?(source, value)
        end

        private

        def by_source
          @by_source ||= begin
            decisions = ::MatchDecision.verdict_rejected.where(subject: @author, finder: FINDERS.keys).to_a
            redirected = redirected_from_by_decision(decisions.select { |decision| FINDERS.fetch(decision.finder) == "wikidata" })
            decisions.each_with_object({}) do |decision, sets|
              source = FINDERS.fetch(decision.finder)
              set = (sets[source] ||= Set.new)
              key = decision.selected_candidate&.dig("external_key")
              set << key.to_s if key.present?
              set.merge(redirected.fetch(decision.id, []).map(&:to_s)) if source == "wikidata"
            end
          end
        end

        # {decision_id => ["Q9", ...]}, read in one query for every rejected
        # Wikidata decision at once.
        def redirected_from_by_decision(wikidata_decisions)
          return {} if wikidata_decisions.empty?

          ::Enrichment.where(match_decision_id: wikidata_decisions.map(&:id))
            .each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |row, map|
              fact = row.facts["wikidata_qid"]
              map[row.match_decision_id].concat(Array(fact["redirected_from"])) if fact.is_a?(Hash)
            end
        end
      end
    end
  end
end
