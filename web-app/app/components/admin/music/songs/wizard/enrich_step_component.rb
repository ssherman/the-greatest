# frozen_string_literal: true

class Admin::Music::Songs::Wizard::EnrichStepComponent < ViewComponent::Base
  def initialize(list:, unverified_items: nil, enriched_count: nil)
    @list = list
    @unverified_items = unverified_items || list.list_items.unverified.ordered
    @total_items = @unverified_items.count
    @enriched_count = enriched_count || @unverified_items.where.not(listable_id: nil).count
  end

  private

  attr_reader :list, :unverified_items, :total_items, :enriched_count

  def enrich_status
    list.wizard_manager.step_status("enrich")
  end

  def enrich_progress
    list.wizard_manager.step_progress("enrich")
  end

  def enrich_error
    list.wizard_manager.step_error("enrich")
  end

  def job_metadata
    list.wizard_manager.step_metadata("enrich")
  end

  def opensearch_matches
    job_metadata["opensearch_matches"] || 0
  end

  def musicbrainz_matches
    job_metadata["musicbrainz_matches"] || 0
  end

  def not_found_count
    job_metadata["not_found"] || 0
  end

  def processed_items
    job_metadata["processed_items"] || 0
  end

  def total_from_metadata
    job_metadata["total_items"] || total_items
  end

  def percentage(count)
    return 0 if total_from_metadata.zero?
    ((count.to_f / total_from_metadata) * 100).round(1)
  end

  def preview_items
    @unverified_items.includes(listable: :artists)
  end

  def idle_or_failed?
    %w[idle failed].include?(enrich_status)
  end

  def running?
    enrich_status == "running"
  end

  def completed?
    enrich_status == "completed"
  end

  def failed?
    enrich_status == "failed"
  end
end
