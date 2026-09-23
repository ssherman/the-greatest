# frozen_string_literal: true

module DataImporters
  # Turns SelectCandidateTask's data into a Decision: the selection itself,
  # the ranked post-rule (a ranked record wins a same-entity group over the
  # unranked pick), and the duplicate pairs every same-entity group of two
  # local records implies. A pair a human ruled not_duplicate is neither
  # re-raised nor used to switch the selection.
  class AiSelection
    def initialize(finder:, shown:, data:)
      @finder = finder
      @shown = shown
      @data = data
    end

    def call
      index = @data[:selected_index].to_i
      chosen = index.positive? ? @shown[index - 1] : nil
      confidence = @data[:confidence].to_s.to_sym
      reason = @data[:reasoning].to_s
      pairs = []

      Array(@data[:same_entity_groups]).each do |members|
        group = members.filter_map { |m| @shown[m - 1] }
        locals = group.select(&:local?)
        locals.combination(2).each do |a, b|
          next if @finder.never_merge?(a.record, b.record)

          pairs << [a.record, b.record, :ai]
        end

        next unless chosen&.local? && !chosen.ranked? && members.include?(index)

        ranked = locals.find { |c| c.ranked? && !c.equal?(chosen) }
        next unless ranked && !@finder.never_merge?(chosen.record, ranked.record)

        reason = "#{reason} Preferred ranked ##{ranked.evidence[:ranked_position]} #{ranked.evidence[:title]} over the unranked pick.".strip
        index = @shown.index(ranked) + 1
        chosen = ranked
      end

      if chosen.nil?
        Decision.new(outcome: :unmatched, record: nil, confidence: confidence, decided_by: :ai, reason: reason,
          external: nil, selected_index: nil, duplicate_pairs: pairs)
      elsif chosen.local?
        Decision.new(outcome: :matched, record: chosen.record, confidence: confidence, decided_by: :ai, reason: reason,
          external: (chosen.external? ? chosen : nil), selected_index: index, duplicate_pairs: pairs)
      else
        Decision.new(outcome: :unmatched, record: nil, confidence: confidence, decided_by: :ai, reason: reason,
          external: chosen, selected_index: index, duplicate_pairs: pairs)
      end
    end
  end
end
