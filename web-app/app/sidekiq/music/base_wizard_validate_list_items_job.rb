# frozen_string_literal: true

# Base class for wizard validate jobs.
# Validates enriched list items using AI to check match quality.
#
# Subclasses must implement:
#   - list_class: Model class for list (e.g., Music::Songs::List)
#   - validator_task_class: AI task class for validation
#   - entity_id_key: Metadata key for entity ID (e.g., "song_id")
#   - enrichment_id_key: Metadata key for MusicBrainz ID (e.g., "mb_recording_id")
#
class Music::BaseWizardValidateListItemsJob
  include Sidekiq::Job

  def perform(list_id)
    @list = list_class.find(list_id)
    @items = enriched_items

    if @items.empty?
      complete_with_no_items
      return
    end

    @list.wizard_manager.update_step_status!(step: "validate", status: "running", progress: 0, metadata: {})

    clear_previous_validation_flags

    result = validator_task_class.new(parent: @list).call

    if result.success?
      complete_job(result.data)
    else
      handle_error(result.error || "Validation failed")
    end
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error "#{self.class.name}: List not found - #{e.message}"
    raise
  rescue => e
    Rails.logger.error "#{self.class.name} failed for list #{list_id}: #{e.message}"
    handle_error(e.message) if @list
    raise
  end

  private

  # Abstract methods - subclasses must implement
  def list_class
    raise NotImplementedError, "Subclass must implement #list_class"
  end

  def validator_task_class
    raise NotImplementedError, "Subclass must implement #validator_task_class"
  end

  def entity_id_key
    raise NotImplementedError, "Subclass must implement #entity_id_key"
  end

  def enrichment_id_key
    raise NotImplementedError, "Subclass must implement #enrichment_id_key"
  end

  # Shared implementation methods

  def enriched_items
    @list.list_items.unverified.ordered.select do |item|
      item.listable_id.present? ||
        item.metadata[entity_id_key].present? ||
        item.metadata[enrichment_id_key].present?
    end
  end

  def clear_previous_validation_flags
    @list.list_items.find_each do |item|
      needs_update = false

      if item.metadata["ai_match_invalid"].present?
        item.metadata.delete("ai_match_invalid")
        needs_update = true
      end

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
      item.metadata[entity_id_key].present? ||
      item.metadata[enrichment_id_key].present?
  end

  def complete_with_no_items
    @list.wizard_manager.update_step_status!(
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

    Rails.logger.info "#{self.class.name} completed for list #{@list.id}: No items to validate"
  end

  def complete_job(data)
    @list.wizard_manager.update_step_status!(
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

    Rails.logger.info "#{self.class.name} completed for list #{@list.id}: " \
      "#{data[:valid_count]} valid, #{data[:invalid_count]} invalid, #{data[:verified_count]} verified"
  end

  def handle_error(error_message)
    @list.wizard_manager.update_step_status!(
      step: "validate",
      status: "failed",
      progress: 0,
      error: error_message
    )
  end
end
