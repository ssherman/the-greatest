# frozen_string_literal: true

# The live numbers behind the current rankings.
#
# The weight floor is derived per configuration as
# RankingConfiguration#weight_floor (max(min_list_weight, 0)) rather than
# printed straight from min_list_weight -- total penalty is capped at 100%,
# so weight can never fall below 0, and a negative stored minimum (books
# carries -50) is unreachable, but a positive one (music, games carry 1) is
# reachable and must be shown.
#
# median_list_counts and median_voter_counts are passed in from
# ExplainerData rather than computed here: both issue real queries
# (List.median_list_count, RankingConfiguration#median_voter_count), and the
# spec requires every query to live in ExplainerData so the N+1 guard has one
# place to point at.
class Rankings::ConfigurationFactsComponent < ViewComponent::Base
  def initialize(configurations:, median_list_counts:, median_voter_counts:)
    @configurations = configurations
    @median_list_counts = median_list_counts
    @median_voter_counts = median_voter_counts
  end

  private

  attr_reader :configurations, :median_list_counts, :median_voter_counts

  def weight_floor(configuration) = configuration.weight_floor

  def typical_list_length(configuration) = median_list_counts[configuration]

  def typical_voter_count(configuration) = median_voter_counts[configuration]
end
