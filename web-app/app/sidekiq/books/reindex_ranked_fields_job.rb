class Books::ReindexRankedFieldsJob
  include Sidekiq::Job

  BATCH_SIZE = 1000

  def perform
    config = Books::RankingConfiguration.default_primary
    raise "No primary Books::RankingConfiguration; ranked fields not refreshed" if config.nil?

    total = 0
    failed = 0
    RankedItem
      .where(ranking_configuration_id: config.id, item_type: "Books::Book")
      .where.not(rank: nil)
      .in_batches(of: BATCH_SIZE) do |batch|
        ids_and_ranks = batch.pluck(:item_id, :rank)
        book_ids = ids_and_ranks.map(&:first)
        listed_book_ids = ListItem.where(listable_type: "Books::Book", listable_id: book_ids)
          .distinct.pluck(:listable_id).to_set

        updates = ids_and_ranks.to_h do |item_id, rank|
          [item_id, {ranked_position: rank, ranked: listed_book_ids.include?(item_id)}]
        end

        response = Search::Books::BookIndex.bulk_update(updates)
        failed += response["items"].count { |item| item["update"]["error"] } if response && response["errors"]
        total += updates.size
      end

    if failed > 0
      raise "Failed to refresh ranked fields for #{failed}/#{total} books"
    end

    Rails.logger.info "Refreshed ranked fields for #{total} books"
  end
end
