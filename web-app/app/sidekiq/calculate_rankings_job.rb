# Transitional -- delete this class and test/sidekiq/calculate_rankings_job_test.rb
# in the release after the one that introduced it. Every recalculation now goes
# through Services::RankingConfigurations::RequestRefresh and
# RankingConfigurations::RefreshJob. This only exists so the jobs already in
# Redis when that shipped -- thousands of them after a merge session -- collapse
# into one claimed refresh per configuration instead of dying with NameError.
class CalculateRankingsJob
  include Sidekiq::Job

  def perform(ranking_configuration_id)
    config = RankingConfiguration.find_by(id: ranking_configuration_id)
    return if config.nil?

    Services::RankingConfigurations::RequestRefresh.call(config: config)
  end
end
