# frozen_string_literal: true

# Recalculates one user-owned ranking configuration: list weights first, then
# item rankings, as one unit of work. Status lives on the configuration row
# (RankingConfiguration#refresh_status), which is why this never retries --
# the Refresh button is the retry, and a Sidekiq retry would rerun invisibly
# while the row still said "failed".
#
# Calls the calculators directly rather than CalculateRankingsJob so none of
# the primary-only side effects (author rankings, search reindex) can follow.
module RankingConfigurations
  class RefreshJob
    include Sidekiq::Job

    sidekiq_options queue: :low, retry: false

    def perform(ranking_configuration_id)
      config = ::RankingConfiguration.find_by(id: ranking_configuration_id)
      return if config.nil? # deleted while queued -- not a failure

      config.update_columns(refresh_status: ::RankingConfiguration.refresh_statuses[:running])

      weights = Rankings::BulkWeightCalculator.new(config).call
      if weights[:errors].any?
        first = weights[:errors].first
        raise "Weight calculation failed for #{weights[:errors].size} list(s): #{first[:list_name]}: #{first[:error]}"
      end

      result = config.calculate_rankings
      raise "Ranking calculation failed: #{result.errors.join(", ")}" unless result.success?

      config.update_columns(
        refresh_status: ::RankingConfiguration.refresh_statuses[:idle],
        needs_refresh: false,
        last_refreshed_at: Time.current,
        last_refresh_error: nil
      )
    rescue => e
      Rails.logger.error "[RankingConfigurations::RefreshJob] configuration #{ranking_configuration_id}: #{e.message}"
      ::RankingConfiguration.where(id: ranking_configuration_id).update_all(
        refresh_status: ::RankingConfiguration.refresh_statuses[:failed],
        last_refresh_error: e.message.truncate(500)
      )
    end
  end
end
