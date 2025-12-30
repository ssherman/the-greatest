# frozen_string_literal: true

# Base class for wizard import jobs.
# Imports entities from MusicBrainz and links them to list items.
#
# Subclasses must implement:
#   - list_class: Model class for list (e.g., Music::Songs::List)
#   - enrichment_id_key: Metadata key for MusicBrainz ID (e.g., "mb_recording_id")
#   - importer_class: DataImporter class for entity creation
#   - importer_params(mb_id): Hash of params for importer call
#   - imported_id_key: Metadata key for imported entity ID (e.g., "imported_song_id")
#
# Subclasses may optionally override:
#   - import_from_series: Custom series import logic (default: falls back to custom_html)
#   - series_importer_class: Importer for series (songs only)
#
class Music::BaseWizardImportJob
  include Sidekiq::Job

  PROGRESS_UPDATE_INTERVAL = 10

  def perform(list_id)
    @list = list_class.find(list_id)
    @last_progress_update = Time.current
    import_source = @list.wizard_state&.dig("import_source")

    if import_source == "musicbrainz_series"
      import_from_series
    else
      import_from_custom_html
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

  def enrichment_id_key
    raise NotImplementedError, "Subclass must implement #enrichment_id_key"
  end

  def importer_class
    raise NotImplementedError, "Subclass must implement #importer_class"
  end

  def importer_params(mb_id)
    raise NotImplementedError, "Subclass must implement #importer_params"
  end

  def imported_id_key
    raise NotImplementedError, "Subclass must implement #imported_id_key"
  end

  # Optional override for series import - default falls back to custom_html logic
  def import_from_series
    @list.wizard_manager.update_step_status!(step: "import", status: "running", progress: 0, metadata: {
      "import_source" => "musicbrainz_series"
    })

    # Default: fall back to importing items that have MB data
    @items_to_import = items_needing_import
    @total = @items_to_import.count

    if @total.zero?
      complete_with_no_items("musicbrainz_series")
      return
    end

    @stats = {imported: 0, skipped: 0, failed: 0, errors: []}

    @items_to_import.each_with_index do |item, index|
      import_item(item)
      update_progress(index + 1, "musicbrainz_series") if should_update_progress?(index)
    end

    complete_job("musicbrainz_series")
  end

  def import_from_custom_html
    @items_to_import = items_needing_import
    @total = @items_to_import.count

    if @total.zero?
      complete_with_no_items("custom_html")
      return
    end

    @list.wizard_manager.update_step_status!(step: "import", status: "running", progress: 0, metadata: {
      "import_source" => "custom_html",
      "processed_items" => 0,
      "total_items" => @total,
      "imported_count" => 0,
      "skipped_count" => 0,
      "failed_count" => 0
    })

    @stats = {imported: 0, skipped: 0, failed: 0, errors: []}

    @items_to_import.each_with_index do |item, index|
      import_item(item)
      update_progress(index + 1, "custom_html") if should_update_progress?(index)
    end

    complete_job("custom_html")
  end

  def items_needing_import
    @list.list_items
      .where(listable_id: nil)
      .where("metadata->>'#{enrichment_id_key}' IS NOT NULL")
      .where("metadata->>'imported_at' IS NULL")
      .where("metadata->>'ai_match_invalid' IS NULL OR metadata->>'ai_match_invalid' != 'true'")
      .ordered
  end

  def import_item(item)
    mb_id = item.metadata[enrichment_id_key]

    begin
      result = importer_class.call(**importer_params(mb_id))

      if result.success? && result.item&.persisted?
        item.update!(
          listable: result.item,
          verified: true,
          metadata: item.metadata.merge(
            "imported_at" => Time.current.iso8601,
            imported_id_key => result.item.id
          )
        )
        @stats[:imported] += 1
      else
        error_msg = result.all_errors&.join(", ").presence || "Import failed"
        store_import_error(item, error_msg)
        @stats[:failed] += 1
        @stats[:errors] << {item_id: item.id, title: item.metadata["title"], error: error_msg}
      end
    rescue => e
      Rails.logger.error "#{self.class.name}: Failed to import item #{item.id}: #{e.message}"
      store_import_error(item, e.message)
      @stats[:failed] += 1
      @stats[:errors] << {item_id: item.id, title: item.metadata["title"], error: e.message}
    end
  end

  def store_import_error(item, error_message)
    item.update!(
      metadata: item.metadata.merge(
        "import_error" => error_message,
        "import_attempted_at" => Time.current.iso8601
      )
    )
  end

  def should_update_progress?(index)
    return true if (index + 1) == @total
    return true if (index + 1) % PROGRESS_UPDATE_INTERVAL == 0
    return true if Time.current - @last_progress_update >= 5.seconds
    false
  end

  def update_progress(processed, import_source)
    progress_percent = ((processed.to_f / @total) * 100).round

    @list.wizard_manager.update_step_status!(
      step: "import",
      status: "running",
      progress: progress_percent,
      metadata: {
        "import_source" => import_source,
        "processed_items" => processed,
        "total_items" => @total,
        "imported_count" => @stats[:imported],
        "skipped_count" => @stats[:skipped],
        "failed_count" => @stats[:failed]
      }
    )

    @last_progress_update = Time.current
    Rails.logger.debug "#{self.class.name}: Progress #{processed}/#{@total} (#{progress_percent}%)"
  end

  def complete_job(import_source)
    @list.wizard_manager.update_step_status!(
      step: "import",
      status: "completed",
      progress: 100,
      metadata: {
        "import_source" => import_source,
        "processed_items" => @total,
        "total_items" => @total,
        "imported_count" => @stats[:imported],
        "skipped_count" => @stats[:skipped],
        "failed_count" => @stats[:failed],
        "errors" => @stats[:errors],
        "imported_at" => Time.current.iso8601
      }
    )

    Rails.logger.info "#{self.class.name} completed for list #{@list.id}: " \
      "#{@stats[:imported]} imported, #{@stats[:skipped]} skipped, #{@stats[:failed]} failed"
  end

  def complete_with_no_items(import_source)
    @list.wizard_manager.update_step_status!(
      step: "import",
      status: "completed",
      progress: 100,
      metadata: {
        "import_source" => import_source,
        "processed_items" => 0,
        "total_items" => 0,
        "imported_count" => 0,
        "skipped_count" => 0,
        "failed_count" => 0,
        "errors" => [],
        "imported_at" => Time.current.iso8601
      }
    )

    Rails.logger.info "#{self.class.name} completed for list #{@list.id}: No items to import"
  end

  def handle_error(error_message)
    @list.wizard_manager.update_step_status!(
      step: "import",
      status: "failed",
      progress: 0,
      error: error_message
    )
  end
end
