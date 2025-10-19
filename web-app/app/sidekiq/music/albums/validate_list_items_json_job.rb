class Music::Albums::ValidateListItemsJsonJob
  include Sidekiq::Job

  def perform(list_id)
    list = ::Music::Albums::List.find(list_id)

    result = Services::Ai::Tasks::Lists::Music::Albums::ItemsJsonValidatorTask.new(parent: list).call

    if result.success?
      data = result.data
      Rails.logger.info "ValidateListItemsJsonJob completed for list #{list_id}: #{data[:valid_count]} valid, #{data[:invalid_count]} invalid"
    else
      Rails.logger.error "ValidateListItemsJsonJob failed for list #{list_id}: #{result.error}"
    end
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error "ValidateListItemsJsonJob: List not found - #{e.message}"
    raise
  rescue => e
    Rails.logger.error "ValidateListItemsJsonJob failed: #{e.message}"
    raise
  end
end
