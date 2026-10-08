# frozen_string_literal: true

module Recommendations
  # One reason per recommended item (spec §8.3), most persuasive first:
  # because_of (collaborative evidence), interests (the two strongest profile
  # categories the item carries, above explain_threshold so "Fiction" is never
  # the reason), then the global rank.
  module Explainer
    def self.call(candidate:, profile:, categories:, config:)
      because_of = candidate.evidence&.dig(:because_of)
      return Reason.new(type: :because_of, ids: [because_of]) if because_of

      threshold = config[:explain_threshold].to_f
      interests = categories
        .filter_map { |fact| ((w = profile.weight_for(fact.id)) && w >= threshold) ? [fact.id, w] : nil }
        .sort_by { |id, w| [-w, id] }
        .first(2)
        .map(&:first)
      return Reason.new(type: :interests, ids: interests) if interests.any?

      Reason.new(type: :ranked, ids: [candidate.rank_position].compact)
    end
  end
end
