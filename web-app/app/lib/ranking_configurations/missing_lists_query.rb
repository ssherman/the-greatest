# frozen_string_literal: true

# Lists in the domain's official ranking that a user-owned configuration
# lacks, as the official configuration's RankedList rows (so the weight
# shown is the official one). Diffs against the CURRENT primary rather than
# inherited_from so it stays right when a new primary is promoted, and works
# for a configuration that started from scratch.
module RankingConfigurations
  class MissingListsQuery
    def self.call(config:, entry:)
      primary = entry.ranking_configuration_class.constantize.default_primary
      return ::RankedList.none if primary.nil? || primary.id == config.id

      primary.ranked_lists
        .joins(:list)
        .includes(:list)
        .where(lists: {status: ::List.statuses[:active]})
        .where.not(list_id: config.ranked_lists.select(:list_id))
        .order(weight: :desc, id: :asc)
    end
  end
end
