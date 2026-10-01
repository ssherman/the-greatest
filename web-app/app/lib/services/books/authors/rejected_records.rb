# frozen_string_literal: true

module Services
  module Books
    module Authors
      # The external records a person rejected for one author (spec §12): the
      # candidate each rejected Wikidata or VIAF decision selected. The
      # resolvers never consider them again, and FactSheet#stamp never puts
      # their ids back on the author. One query, on first use.
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
          @by_source ||= ::MatchDecision.verdict_rejected.where(subject: @author, finder: FINDERS.keys)
            .each_with_object({}) do |decision, sets|
              key = decision.selected_candidate&.dig("external_key")
              (sets[FINDERS.fetch(decision.finder)] ||= Set.new) << key.to_s if key.present?
            end
        end
      end
    end
  end
end
