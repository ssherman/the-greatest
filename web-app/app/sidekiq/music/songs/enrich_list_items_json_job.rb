class Music::Songs::EnrichListItemsJsonJob
  include Sidekiq::Job

  def perform(list_id)
    list = ::Music::Songs::List.find(list_id)
    result = Services::Lists::Music::Songs::ItemsJsonEnricher.call(list: list)

    if result[:success]
      Rails.logger.info "EnrichListItemsJsonJob completed for list #{list_id}: #{result[:message]}"
    else
      Rails.logger.error "EnrichListItemsJsonJob failed for list #{list_id}: #{result[:message]}"
    end
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error "EnrichListItemsJsonJob: List not found - #{e.message}"
    raise
  rescue => e
    Rails.logger.error "EnrichListItemsJsonJob failed: #{e.message}"
    raise
  end
end
