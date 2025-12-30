# frozen_string_literal: true

# Base class for wizard enrich jobs.
# Enriches list items with OpenSearch and MusicBrainz data.
#
# Subclasses must implement:
#   - list_class: Model class for list (e.g., Music::Songs::List)
#   - enricher_class: Service class for enrichment
#   - enrichment_keys: Array of metadata keys to clear on re-enrich
#
class Music::BaseWizardEnrichListItemsJob
  include Sidekiq::Job

  PROGRESS_UPDATE_INTERVAL = 10

  def perform(list_id)
    @list = list_class.find(list_id)
    @items = @list.list_items.unverified.ordered
    @total = @items.count

    if @total.zero?
      handle_error("No items to enrich")
      return
    end

    @list.wizard_manager.update_step_status!(step: "enrich", status: "running", progress: 0, metadata: {
      "processed_items" => 0,
      "total_items" => @total,
      "opensearch_matches" => 0,
      "musicbrainz_matches" => 0,
      "not_found" => 0
    })

    clear_previous_enrichment_data

    @stats = {opensearch_matches: 0, musicbrainz_matches: 0, not_found: 0}
    @last_progress_update = Time.current

    @items.each_with_index do |item, index|
      enrich_item(item)
      update_progress(index + 1) if should_update_progress?(index)
    end

    complete_job
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

  def enricher_class
    raise NotImplementedError, "Subclass must implement #enricher_class"
  end

  def enrichment_keys
    raise NotImplementedError, "Subclass must implement #enrichment_keys"
  end

  # Shared implementation methods

  def enrich_item(item)
    result = enricher_class.call(list_item: item)

    case result[:source]
    when :opensearch then @stats[:opensearch_matches] += 1
    when :musicbrainz then @stats[:musicbrainz_matches] += 1
    else @stats[:not_found] += 1
    end
  rescue => e
    Rails.logger.warn "#{self.class.name}: Failed to enrich item #{item.id}: #{e.message}"
    @stats[:not_found] += 1
  end

  def clear_previous_enrichment_data
    @items.find_each do |item|
      cleaned_metadata = item.metadata.except(*enrichment_keys)
      item.update_columns(listable_id: nil, metadata: cleaned_metadata)
    end
  end

  def should_update_progress?(index)
    return true if (index + 1) == @total
    return true if (index + 1) % PROGRESS_UPDATE_INTERVAL == 0
    return true if Time.current - @last_progress_update >= 5.seconds
    false
  end

  def update_progress(processed)
    progress_percent = ((processed.to_f / @total) * 100).round

    @list.wizard_manager.update_step_status!(
      step: "enrich",
      status: "running",
      progress: progress_percent,
      metadata: {
        "processed_items" => processed,
        "total_items" => @total,
        "opensearch_matches" => @stats[:opensearch_matches],
        "musicbrainz_matches" => @stats[:musicbrainz_matches],
        "not_found" => @stats[:not_found]
      }
    )

    @last_progress_update = Time.current
    Rails.logger.debug "#{self.class.name}: Progress #{processed}/#{@total} (#{progress_percent}%)"
  end

  def complete_job
    @list.wizard_manager.update_step_status!(
      step: "enrich",
      status: "completed",
      progress: 100,
      metadata: {
        "processed_items" => @total,
        "total_items" => @total,
        "opensearch_matches" => @stats[:opensearch_matches],
        "musicbrainz_matches" => @stats[:musicbrainz_matches],
        "not_found" => @stats[:not_found],
        "enriched_at" => Time.current.iso8601
      }
    )

    Rails.logger.info "#{self.class.name} completed for list #{@list.id}: " \
      "#{@stats[:opensearch_matches]} OpenSearch, #{@stats[:musicbrainz_matches]} MusicBrainz, #{@stats[:not_found]} not found"
  end

  def handle_error(error_message)
    @list.wizard_manager.update_step_status!(
      step: "enrich",
      status: "failed",
      progress: 0,
      error: error_message
    )
  end
end
