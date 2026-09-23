# frozen_string_literal: true

module DataImporters
  # Base class for finding an existing record before import.
  #
  # A finder answers "is this thing already in our catalog?" with a Match
  # (matched or unmatched, with confidence, the candidates considered, who
  # decided and why) and records that answer as a MatchDecision. The four
  # stages are fixed: gather candidates from the sources, apply the rules,
  # ask the AI when the rules could not decide, record. A domain subclass
  # supplies the sources and the hooks the rules and the AI prompt need.
  #
  # The finder never creates or mutates catalog records and is not
  # transactional. It can be called on its own (the wizard enrichers do).
  class FinderBase
    MAX_AI_CANDIDATES = 6

    Run = Struct.new(
      :query, :verify, :subject, :exclude, :candidates, :sources_run,
      :sources_failed, :external_resolution, :decision, :ai_chat,
      keyword_init: true
    )

    def call(query:, verify: false, subject: nil, exclude: nil)
      run = Run.new(query: query, verify: verify, subject: subject, exclude: exclude,
        candidates: [], sources_run: 0, sources_failed: [])
      gather(run)
      decide(run)
      record(run)
    end

    # ---- judgements the Decider and AiSelection ask for ----------------------

    def titles_agree?(query, record)
      wanted = normalize(query_title(query))
      return false if wanted.blank?

      ([record_title(record)] + record_alternate_titles(record)).any? { |title| normalize(title) == wanted }
    end

    def creators_agree?(query, record)
      wanted = query_creators(query).map { |name| normalize(name) }.compact_blank
      return false if wanted.empty?

      held = (record_creators(record) + record_creator_alternate_names(record)).map { |name| normalize(name) }.compact_blank
      (wanted & held).any?
    end

    # An identifier (or an external accept) is trusted only when the record
    # agrees with the query on its title or its creators, or when the query
    # carried nothing to compare (an identifier-only import).
    def corroborated?(query, candidate)
      return true if query_title(query).blank? && query_creators(query).empty?

      titles_agree?(query, candidate.record) || creators_agree?(query, candidate.record)
    end

    # Rule 4's test: equal normalized title, agreeing creators where the
    # domain has creators, and no year conflict (both present, > 2 apart).
    def exact_match?(query, candidate)
      return false unless titles_agree?(query, candidate.record)
      return false if creators_required? && !creators_agree?(query, candidate.record)

      !year_conflict?(query_year(query), record_year(candidate.record))
    end

    def ranked_position(record)
      configuration = ranking_configuration_class&.default_primary
      return nil unless configuration

      ::RankedItem.where(item: record, ranking_configuration_id: configuration.id).pick(:rank)
    end

    def ranked?(record)
      ranked_position(record).present?
    end

    def list_count(record)
      record.respond_to?(:list_items) ? record.list_items.count : 0
    end

    def never_merge?(record_a, record_b)
      ::DuplicateCandidate.not_duplicate?(item_type: model_class.name, ids: [record_a.id, record_b.id])
    end

    def describe_query(query)
      parts = [query_title(query).presence]
      creators = query_creators(query)
      parts << "by #{creators.join(", ")}" if creators.any?
      parts << "(#{query_year(query)})" if query_year(query).present?
      parts.compact.join(" | ")
    end

    def describe_candidate(candidate)
      evidence = candidate.evidence
      creators = Array(evidence[:creators])
      parts = [evidence[:title].presence || candidate.external_key.to_s]
      parts << "by #{creators.join(", ")}" if creators.any?
      parts << "(#{evidence[:year]})" if evidence[:year].present?
      parts << "ranked ##{evidence[:ranked_position]}" if evidence[:ranked_position].present?
      parts << "in catalog" if candidate.local?
      parts << "#{candidate.external_source} #{candidate.external_key}" if candidate.external?
      parts << "shares #{evidence.dig(:matched_identifier, :type)}" if evidence[:matched_identifier]
      parts << "#{candidate.external_source} verdict #{candidate.external_verdict}" if candidate.external_verdict
      parts.join(" | ")
    end

    protected

    # ---- hooks a domain subclass overrides ------------------------------------

    def candidate_sources(query)
      raise NotImplementedError, "#{self.class.name} must implement #candidate_sources(query)"
    end

    def model_class
      raise NotImplementedError, "#{self.class.name} must implement #model_class"
    end

    def entity_noun
      model_class.name.demodulize.underscore.humanize.downcase
    end

    def ranking_configuration_class
      nil
    end

    def domain_guidance
      ""
    end

    def creators_required?
      false
    end

    def query_title(query)
      return query.title if query.respond_to?(:title)
      return query.name if query.respond_to?(:name)

      nil
    end

    def query_creators(_query)
      []
    end

    def query_year(query)
      query.respond_to?(:year) ? query.year : nil
    end

    def record_title(record)
      record.respond_to?(:title) ? record.title : record.name
    end

    def record_alternate_titles(record)
      return Array(record.alternate_titles) if record.respond_to?(:alternate_titles)
      return Array(record.alternate_names) if record.respond_to?(:alternate_names)

      []
    end

    def record_creators(_record)
      []
    end

    def record_creator_alternate_names(_record)
      []
    end

    def record_year(_record)
      nil
    end

    def record_identifiers(record)
      return [] unless record.respond_to?(:identifiers)

      record.identifiers.map { |identifier| {type: identifier.identifier_type, value: identifier.value} }
    end

    # Kept for the legacy lookups (increment 1); the Identifiers source
    # replaces it as each domain migrates.
    def find_by_identifier(identifier_type:, identifier_value:, model_class:)
      identifier = ::Identifier.includes(:identifiable).find_by(
        identifier_type: identifier_type,
        value: identifier_value,
        identifiable_type: model_class.name
      )

      identifier&.identifiable
    end

    private

    # ---- stage 1: gather ------------------------------------------------------

    def gather(run)
      set = CandidateSet.new
      candidate_sources(run.query).each do |source|
        run.sources_run += 1
        begin
          found = source.call
        rescue => e
          Rails.logger.warn "#{self.class.name}: source #{source.name} failed: #{e.class}: #{e.message}"
          run.sources_failed << source.name.to_s
          next
        end
        run.external_resolution ||= source.resolution if source.respond_to?(:resolution)

        found.each do |candidate|
          next if excluded?(run, candidate)

          candidate.evidence = evidence_for(candidate.record).merge(candidate.evidence) { |_key, base, given| given.nil? ? base : given } if candidate.local?
          set.add(candidate)
        end

        break if !run.verify && set.to_a.any? { |candidate| decisive?(run.query, candidate) }
      end
      run.candidates = order(set.to_a)
    end

    def excluded?(run, candidate)
      run.exclude && candidate.local? &&
        candidate.record.instance_of?(run.exclude.class) && candidate.record.id == run.exclude.id
    end

    def decisive?(query, candidate)
      return true if candidate.sources.include?(:legacy)
      return false unless candidate.local?

      (candidate.sources.include?(:identifier) || candidate.external_accepted?) && corroborated?(query, candidate)
    end

    def evidence_for(record)
      {
        title: record_title(record),
        creators: record_creators(record),
        year: record_year(record),
        ranked_position: ranked_position(record),
        list_count: list_count(record),
        identifiers: record_identifiers(record)
      }
    end

    # Local and multi-source candidates first, then by best score; stable.
    def order(candidates)
      candidates.each_with_index.sort_by do |candidate, index|
        [candidate.local? ? 0 : 1, -candidate.sources.size, -(candidate.scores.values.compact.max || 0.0), index]
      end.map(&:first)
    end

    # ---- stage 2 and 3: rules, then the AI -----------------------------------

    def decide(run)
      run.decision = Decider.new(finder: self, query: run.query, candidates: run.candidates,
        verify: run.verify, sources_run: run.sources_run).call
      return if run.decision

      shown = run.candidates.first(MAX_AI_CANDIDATES)
      begin
        task = ::Services::Ai::Tasks::Matching::SelectCandidateTask.new(
          parent: run.subject,
          entity_noun: entity_noun,
          query_line: describe_query(run.query),
          candidate_lines: shown.map { |candidate| describe_candidate(candidate) },
          guidance: domain_guidance
        )
        result = task.call
      rescue => e
        Rails.logger.error "#{self.class.name}: AI selection raised #{e.class}: #{e.message}"
        run.decision = Decision.fallback("AI selection failed: #{e.class}: #{e.message}")
        return
      end

      run.ai_chat = result.ai_chat
      run.decision = if result.success?
        AiSelection.new(finder: self, shown: shown, data: result.data).call
      else
        Decision.fallback("AI selection failed: #{result.error}")
      end
    end

    # ---- stage 4: record ------------------------------------------------------

    def record(run)
      decision = run.decision
      confidence = decision.confidence
      confidence = :medium if confidence == :high && run.sources_failed.any?
      needs_review = %i[medium low].include?(confidence) || decision.decided_by == :fallback
      selected_index = decision.selected_index || index_of(run.candidates, decision.record)

      row = ::MatchDecision.create!(
        finder: self.class.name,
        record: decision.record,
        subject: run.subject,
        outcome: decision.outcome,
        confidence: confidence,
        decided_by: decision.decided_by,
        verify: run.verify,
        query: query_snapshot(run.query),
        candidates: run.candidates.map(&:snapshot),
        selected_index: selected_index,
        reason: decision.reason,
        ai_chat: run.ai_chat,
        sources_failed: run.sources_failed,
        needs_review: needs_review
      )

      pairs = (decision.duplicate_pairs + collision_pairs(run.candidates))
        .uniq { |record_a, record_b, _source| [record_a.id, record_b.id].minmax }
      pairs.each do |record_a, record_b, source|
        ::DuplicateCandidate.flag!(
          item_type: model_class.name, ids: [record_a.id, record_b.id], source: source,
          evidence: {reason: decision.reason, decided_by: decision.decided_by.to_s}, match_decision: row
        )
      end

      Match.new(
        outcome: decision.outcome, record: decision.record, confidence: confidence,
        decided_by: decision.decided_by, reason: decision.reason, candidates: run.candidates,
        external: decision.external, external_resolution: run.external_resolution,
        decision: row, sources_failed: run.sources_failed
      )
    end

    # Two local records carrying the same external key are a suspected pair
    # whatever the rules decided about the incoming item.
    def collision_pairs(candidates)
      candidates.select { |c| c.local? && c.external? }
        .group_by { |c| [c.external_source, c.external_key] }
        .values.select { |group| group.size > 1 }
        .flat_map { |group| group.combination(2).map { |a, b| [a.record, b.record, :external_key_collision] } }
    end

    def index_of(candidates, record)
      return nil unless record

      position = candidates.index { |candidate| candidate.local? && candidate.record.instance_of?(record.class) && candidate.record.id == record.id }
      position && position + 1
    end

    def query_snapshot(query)
      return query.deep_stringify_keys.transform_values { |value| snapshot_value(value) } if query.is_a?(Hash)

      query.instance_variables.to_h do |ivar|
        [ivar.to_s.delete("@"), snapshot_value(query.instance_variable_get(ivar))]
      end
    end

    def snapshot_value(value)
      case value
      when ActiveRecord::Base then "#{value.class.name}##{value.id}"
      when Array then value.map { |item| snapshot_value(item) }
      when Hash then value.to_h { |key, item| [key.to_s, snapshot_value(item)] }
      when String, Integer, Float, TrueClass, FalseClass, NilClass then value
      else value.to_s
      end
    end

    def year_conflict?(year_a, year_b)
      year_a.present? && year_b.present? && (year_a.to_i - year_b.to_i).abs > 2
    end

    def normalize(text)
      return nil if text.nil?

      ::Services::Text::NameNormalizer.call(::Services::Text::QuoteNormalizer.call(text.to_s)).downcase
    end
  end
end
