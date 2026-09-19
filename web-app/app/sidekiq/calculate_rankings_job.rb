class CalculateRankingsJob
  include Sidekiq::Job

  def perform(ranking_configuration_id)
    ranking_configuration = RankingConfiguration.find(ranking_configuration_id)

    result = ranking_configuration.calculate_rankings

    if result.success?
      Rails.logger.info "Successfully calculated rankings for configuration #{ranking_configuration_id}"
      # Both side effects are about the site's official books ranking. A
      # year rollup or a user-owned configuration recalculating must not
      # recompute global author rankings or reindex search.
      if ranking_configuration.type == "Books::RankingConfiguration" && ranking_configuration.default_primary?
        Books::CalculateAuthorRankingsJob.perform_async
        Books::ReindexRankedFieldsJob.perform_async
      end

      request_csv_regenerate(ranking_configuration)
    else
      Rails.logger.error "Failed to calculate rankings for configuration #{ranking_configuration_id}: #{result.errors}"
      raise "Ranking calculation failed: #{result.errors.join(", ")}"
    end
  end

  private

  # The pre-built CSV must never be behind the ranks it describes (spec D4).
  # RequestGenerate is a no-op for a type with no export. Its own rescue: the
  # CSV is a side effect of the calculation, and a DB blip on csv_exports must
  # not make Sidekiq retry a 21k-row ranking that already landed.
  def request_csv_regenerate(ranking_configuration)
    Services::CsvExports::RequestGenerate.call(ranking_configuration: ranking_configuration)
  rescue => e
    Rails.logger.error "[CalculateRankingsJob] configuration #{ranking_configuration.id}: CSV regenerate not requested: #{e.message}"
  end
end
