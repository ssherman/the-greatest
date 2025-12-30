# frozen_string_literal: true

# Base component for wizard validate step.
# Displays AI validation progress and results.
#
# Subclasses must implement:
#   - step_status_path: Path helper for polling step status
#   - advance_step_path: Path helper for advancing to next step
#   - revalidate_path: Path helper for re-validation
#   - entity_id_key: Metadata key for entity ID (e.g., "song_id")
#   - enrichment_id_key: Metadata key for MusicBrainz ID (e.g., "mb_recording_id")
#   - entity_name: "song" or "album" for display text
#
class Admin::Music::Wizard::BaseValidateStepComponent < ViewComponent::Base
  def initialize(list:, enriched_items: nil)
    @list = list
    @unverified_items = list.list_items.unverified.ordered
    all_items = list.list_items.ordered
    @enriched_items = enriched_items || all_items.select { |item| has_enrichment?(item) }
  end

  private

  attr_reader :list, :unverified_items, :enriched_items

  # Abstract methods - subclasses must implement
  def step_status_path
    raise NotImplementedError, "Subclass must implement #step_status_path"
  end

  def advance_step_path
    raise NotImplementedError, "Subclass must implement #advance_step_path"
  end

  def revalidate_path
    raise NotImplementedError, "Subclass must implement #revalidate_path"
  end

  def entity_id_key
    raise NotImplementedError, "Subclass must implement #entity_id_key"
  end

  def enrichment_id_key
    raise NotImplementedError, "Subclass must implement #enrichment_id_key"
  end

  def entity_name
    raise NotImplementedError, "Subclass must implement #entity_name"
  end

  # Shared methods
  def has_enrichment?(item)
    item.listable_id.present? ||
      item.metadata[entity_id_key].present? ||
      item.metadata[enrichment_id_key].present?
  end

  def validate_status
    list.wizard_manager.step_status("validate")
  end

  def validate_progress
    list.wizard_manager.step_progress("validate")
  end

  def validate_error
    list.wizard_manager.step_error("validate")
  end

  def job_metadata
    list.wizard_manager.step_metadata("validate")
  end

  def valid_count
    job_metadata["valid_count"] || 0
  end

  def invalid_count
    job_metadata["invalid_count"] || 0
  end

  def verified_count
    job_metadata["verified_count"] || 0
  end

  def validated_items
    job_metadata["validated_items"] || 0
  end

  def reasoning
    job_metadata["reasoning"]
  end

  def total_items
    @unverified_items.count
  end

  def items_to_validate
    @enriched_items.count
  end

  def percentage(count)
    return 0 if validated_items.zero?
    ((count.to_f / validated_items) * 100).round(1)
  end

  def preview_items
    @enriched_items
  end

  def idle_or_failed?
    %w[idle failed].include?(validate_status)
  end

  def running?
    validate_status == "running"
  end

  def completed?
    validate_status == "completed"
  end

  def failed?
    validate_status == "failed"
  end
end
