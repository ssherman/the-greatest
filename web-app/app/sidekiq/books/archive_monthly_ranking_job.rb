# Daily check (config/schedule.yml) that the books primary ranking has an
# archive for the current UTC month, and creates it if not. sidekiq-cron does
# not catch up on a missed run, so asking every day whether the month has its
# archive is what heals a skipped one. It only reads the configuration: no
# clone, no rename, no refresh.
class Books::ArchiveMonthlyRankingJob
  include Sidekiq::Job

  # Two retries, not Sidekiq's 25: the daily cron already heals a missed run, and each failing day would
  # otherwise start another weeks-long retry chain.
  sidekiq_options queue: :low, retry: 2

  def perform
    config = Books::RankingConfiguration.default_primary

    if config.nil?
      Rails.logger.error "No primary Books::RankingConfiguration; monthly ranking archive not created"
      raise "No primary Books::RankingConfiguration"
    end

    period = Time.now.utc.to_date.beginning_of_month
    return if archived?(config, period)

    result = ::Services::RankingArchives::Capture.call(config: config, name: period.strftime("%B %Y"), period: period)
    return if result.success?
    return if archived?(config, period)

    raise "Monthly ranking archive for #{period} not created: #{result.errors.join(", ")}"
  end

  private

  def archived?(config, period)
    Books::RankingArchive.exists?(ranking_configuration_id: config.id, period: period)
  end
end
