class Music::Songs::WizardValidateListItemsJob
  include Sidekiq::Job

  def perform(list_id)
    @list = Music::Songs::List.find(list_id)
    @items = enriched_items

    if @items.empty?
      complete_with_no_items
      return
    end

    @list.update_wizard_step_status(step: "validate", status: "running", progress: 0, metadata: {})

    clear_previous_validation_flags

    result = Services::Ai::Tasks::Lists::Music::Songs::ListItemsValidatorTask.new(parent: @list).call

    if result.success?
      complete_job(result.data)
    else
      handle_error(result.error || "Validation failed")
    end
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error "WizardValidateListItemsJob: List not found - #{e.message}"
    raise
  rescue => e
    Rails.logger.error "WizardValidateListItemsJob failed for list #{list_id}: #{e.message}"
    handle_error(e.message) if @list
    raise
  end

  private

  def enriched_items
    @list.list_items.unverified.ordered.select do |item|
      item.listable_id.present? ||
        item.metadata["song_id"].present? ||
        item.metadata["mb_recording_id"].present?
    end
  end

  def clear_previous_validation_flags
    # Clear validation flags from ALL items (for idempotency when re-validating)
    @list.list_items.find_each do |item|
      needs_update = false

      if item.metadata["ai_match_invalid"].present?
        item.metadata.delete("ai_match_invalid")
        needs_update = true
      end

      # Reset verified status for items that will be re-validated
      if item.verified && has_enrichment?(item)
        needs_update = true
      end

      if needs_update
        item.update_columns(metadata: item.metadata, verified: false)
      end
    end
  end

  def has_enrichment?(item)
    item.listable_id.present? ||
      item.metadata["song_id"].present? ||
      item.metadata["mb_recording_id"].present?
  end

  def complete_with_no_items
    @list.update_wizard_step_status(
      step: "validate",
      status: "completed",
      progress: 100,
      metadata: {
        "validated_items" => 0,
        "valid_count" => 0,
        "invalid_count" => 0,
        "verified_count" => 0,
        "reasoning" => "No enriched items to validate",
        "validated_at" => Time.current.iso8601
      }
    )

    Rails.logger.info "WizardValidateListItemsJob completed for list #{@list.id}: No items to validate"
  end

  def complete_job(data)
    @list.update_wizard_step_status(
      step: "validate",
      status: "completed",
      progress: 100,
      metadata: {
        "validated_items" => data[:total_count],
        "valid_count" => data[:valid_count],
        "invalid_count" => data[:invalid_count],
        "verified_count" => data[:verified_count],
        "reasoning" => data[:reasoning],
        "validated_at" => Time.current.iso8601
      }
    )

    Rails.logger.info "WizardValidateListItemsJob completed for list #{@list.id}: " \
      "#{data[:valid_count]} valid, #{data[:invalid_count]} invalid, #{data[:verified_count]} verified"
  end

  def handle_error(error_message)
    @list.update_wizard_step_status(
      step: "validate",
      status: "failed",
      progress: 0,
      error: error_message
    )
  end
end
