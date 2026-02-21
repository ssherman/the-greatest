# frozen_string_literal: true

# Base class for wizard validate jobs.
# Validates enriched list items using AI to check match quality.
#
# Supports optional batch processing for large lists (100+ enriched items).
# When batch_mode is enabled in wizard_state, processes items in batches of 100
# to ensure all items are validated.
#
# Subclasses must implement:
#   - list_class: Model class for list (e.g., Music::Songs::List)
#   - validator_task_class: AI task class for validation
#   - entity_id_key: Metadata key for entity ID (e.g., "song_id")
#   - enrichment_id_key: Metadata key for external ID (e.g., "mb_recording_id")
#
class BaseWizardValidateListItemsJob
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

    data = if batch_mode?
      process_in_batches
    else
      result = validator_task_class.new(parent: @list).call
      unless result.success?
        handle_error(result.error || "Validation failed")
        return
      end
      result.data
    end

    complete_job(data)
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
    @list.list_items.reorder(nil).find_each do |item|
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

  # Check if batch mode is enabled in wizard_state
  def batch_mode?
    @list.wizard_state&.dig("batch_mode") == true
  end

  # Process all items in batches of 100
  def process_in_batches
    total_valid = 0
    total_invalid = 0
    total_verified = 0
    last_reasoning = nil
    total_batches = (@items.size.to_f / 100).ceil
    items_validated = 0

    @items.each_slice(100).with_index do |batch_items, batch_index|
      # Call validator task with specific items (ai_chat still associated with @list)
      result = validator_task_class.new(
        parent: @list,
        items: batch_items
      ).call

      unless result.success?
        error_msg = "Batch #{batch_index + 1} failed: #{result.error}"
        handle_error(error_msg)
        raise error_msg
      end

      # Accumulate counts (items already updated by task's process_and_persist)
      total_valid += result.data[:valid_count]
      total_invalid += result.data[:invalid_count]
      total_verified += result.data[:verified_count]
      last_reasoning = result.data[:reasoning]
      items_validated += batch_items.size

      # Update progress
      @list.wizard_manager.update_step_status!(
        step: "validate",
        status: "running",
        progress: ((batch_index + 1).to_f / total_batches * 100).to_i,
        metadata: {
          batches_completed: batch_index + 1,
          total_batches: total_batches,
          items_validated: items_validated
        }
      )
    end

    # Return aggregated counts
    {
      valid_count: total_valid,
      invalid_count: total_invalid,
      verified_count: total_verified,
      total_count: @items.count,
      reasoning: last_reasoning
    }
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
