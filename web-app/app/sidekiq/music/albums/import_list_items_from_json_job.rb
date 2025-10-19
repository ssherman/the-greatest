class Music::Albums::ImportListItemsFromJsonJob
  include Sidekiq::Job

  def perform(list_id)
    list = ::Music::Albums::List.find(list_id)

    result = Services::Lists::Music::Albums::ItemsJsonImporter.call(list: list)

    if result.success
      Rails.logger.info "ImportListItemsFromJsonJob completed for list #{list_id}: imported #{result.imported_count}, created directly #{result.created_directly_count}, skipped #{result.skipped_count}, errors #{result.error_count}"
    else
      Rails.logger.error "ImportListItemsFromJsonJob failed for list #{list_id}: #{result.message}"
    end
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error "ImportListItemsFromJsonJob: List not found - #{e.message}"
    raise
  rescue => e
    Rails.logger.error "ImportListItemsFromJsonJob failed: #{e.message}"
    raise
  end
end
