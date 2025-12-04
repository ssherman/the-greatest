# frozen_string_literal: true

class Admin::Music::Songs::Wizard::ValidateStepComponent < ViewComponent::Base
  def initialize(list:, enriched_items: nil)
    @list = list
    @unverified_items = list.list_items.unverified.ordered
    # For preview, include all items that have enrichment data (both verified and unverified)
    all_items = list.list_items.ordered
    @enriched_items = enriched_items || all_items.select do |item|
      item.listable_id.present? ||
        item.metadata["song_id"].present? ||
        item.metadata["mb_recording_id"].present?
    end
  end

  private

  attr_reader :list, :unverified_items, :enriched_items

  def validate_status
    list.wizard_step_status("validate")
  end

  def validate_progress
    list.wizard_step_progress("validate")
  end

  def validate_error
    list.wizard_step_error("validate")
  end

  def job_metadata
    list.wizard_step_metadata("validate")
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
