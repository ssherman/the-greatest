class ParseListWithAiJob
  include Sidekiq::Job

  def perform(list_id)
    list = List.find(list_id)
    result = list.parse_with_ai!

    if result[:success]
      Rails.logger.info "Successfully parsed list #{list_id}: #{list.name}"
    else
      Rails.logger.error "Failed to parse list #{list_id}: #{result[:error]}"
    end
  rescue => e
    Rails.logger.error "Error processing list #{list_id}: #{e.message}"
    raise # Re-raise to mark job as failed
  end
end
