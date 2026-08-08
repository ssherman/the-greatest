class Books::ReindexRankedFieldsJob
  include Sidekiq::Job

  BATCH_SIZE = 1000

  def perform
    config = Books::RankingConfiguration.default_primary
    raise "No primary Books::RankingConfiguration; ranked fields not refreshed" if config.nil?

    total = 0
    RankedItem
      .where(ranking_configuration_id: config.id, item_type: "Books::Book")
      .where.not(rank: nil)
      .in_batches(of: BATCH_SIZE) do |batch|
        updates = batch.pluck(:item_id, :rank).to_h { |item_id, rank| [item_id, {ranked_position: rank}] }
        Search::Books::BookIndex.bulk_update(updates)
        total += updates.size
      end

    Rails.logger.info "Refreshed ranked_position for #{total} books"
  end
end
