# frozen_string_literal: true

# Recalculates one user-owned ranking configuration: list weights first, then
# item rankings, as one unit of work. Status lives on the configuration row
# (RankingConfiguration#refresh_status), which is why this never retries --
# the Refresh button is the retry, and a Sidekiq retry would rerun invisibly
# while the row still said "failed".
#
# needs_refresh is cleared when the run STARTS, not when it ends: an edit made
# while this job is running (Save, AddLists, remove) sets it back to true, and
# the run in flight is computing from data that no longer matches, so the
# successful-end update must never touch it -- otherwise it would stomp the
# edit's true back to false and the page would claim "Up to date" for
# rankings computed from stale, pre-edit data. A failure sets it back to true
# unconditionally, since whatever it was computing didn't land either way.
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

      config.update_columns(refresh_status: ::RankingConfiguration.refresh_statuses[:running], needs_refresh: false)

      weights = Rankings::BulkWeightCalculator.new(config).call
      if weights[:errors].any?
        first = weights[:errors].first
        raise "Weight calculation failed for #{weights[:errors].size} list(s): #{first[:list_name]}: #{first[:error]}"
      end

      result = config.calculate_rankings
      raise "Ranking calculation failed: #{result.errors.join(", ")}" unless result.success?

      config.update_columns(
        refresh_status: ::RankingConfiguration.refresh_statuses[:idle],
        last_refreshed_at: Time.current,
        last_refresh_error: nil
      )

      request_csv_regenerate(config)
    rescue => e
      Rails.logger.error "[RankingConfigurations::RefreshJob] configuration #{ranking_configuration_id}: #{e.message}"
      ::RankingConfiguration.where(id: ranking_configuration_id).update_all(
        refresh_status: ::RankingConfiguration.refresh_statuses[:failed],
        needs_refresh: true,
        last_refresh_error: e.message.truncate(500)
      )
    end

    private

    # The CSV is a side effect of the refresh, not part of it: a failure here
    # must not flip a configuration whose rankings did land to "failed". Logged
    # rather than raised -- retry: false means a raise would only be logged
    # anyway, and the next Refresh or member download re-claims the row.
    def request_csv_regenerate(config)
      Services::CsvExports::RequestGenerate.call(ranking_configuration: config)
    rescue => e
      Rails.logger.error "[RankingConfigurations::RefreshJob] configuration #{config.id}: CSV regenerate not requested: #{e.message}"
    end
  end
end
