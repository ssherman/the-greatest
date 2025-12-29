# frozen_string_literal: true

# Background job that imports albums from MusicBrainz into the database
# and links them to ListItems in the wizard.
#
# Supports two import paths:
# - custom_html: Imports albums one-by-one from parsed items that have MB release group IDs
# - musicbrainz_series: (Not yet implemented) Would import all albums from a MusicBrainz series
#
# For each item with a MusicBrainz release group ID but no linked album:
# 1. Calls DataImporters::Music::Album::Importer to import/find the album
# 2. Links the imported album to the ListItem via listable association
# 3. Marks the item as verified
# 4. Records import timestamp in item metadata
#
# Progress updates are throttled to reduce database writes while providing
# regular feedback to the user.
class Music::Albums::WizardImportAlbumsJob
  include Sidekiq::Job

  PROGRESS_UPDATE_INTERVAL = 10

  def perform(list_id)
    @list = Music::Albums::List.find(list_id)
    @last_progress_update = Time.current
    import_source = @list.wizard_state&.dig("import_source")

    if import_source == "musicbrainz_series"
      import_from_series
    else
      import_from_custom_html
    end
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error "WizardImportAlbumsJob: List not found - #{e.message}"
    raise
  rescue => e
    Rails.logger.error "WizardImportAlbumsJob failed for list #{list_id}: #{e.message}"
    handle_error(e.message) if @list
    raise
  end

  private

  def import_from_series
    @list.wizard_manager.update_step_status!(step: "import", status: "running", progress: 0, metadata: {
      "import_source" => "musicbrainz_series"
    })

    # Series import for albums is not yet implemented
    # For now, we'll fall back to importing any items that have MB data
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

  # Selects items that are candidates for import:
  # - No linked album (listable_id is nil)
  # - Has a MusicBrainz release group ID in metadata
  # - Not already imported (no imported_at timestamp)
  # - Not marked as invalid by AI validation
  def items_needing_import
    @list.list_items
      .where(listable_id: nil)
      .where("metadata->>'mb_release_group_id' IS NOT NULL")
      .where("metadata->>'imported_at' IS NULL")
      .where("metadata->>'ai_match_invalid' IS NULL OR metadata->>'ai_match_invalid' != 'true'")
      .ordered
  end

  def import_item(item)
    mb_id = item.metadata["mb_release_group_id"]

    begin
      result = DataImporters::Music::Album::Importer.call(release_group_musicbrainz_id: mb_id)

      if result.success? && result.item&.persisted?
        item.update!(
          listable: result.item,
          verified: true,
          metadata: item.metadata.merge(
            "imported_at" => Time.current.iso8601,
            "imported_album_id" => result.item.id
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
      Rails.logger.error "WizardImportAlbumsJob: Failed to import item #{item.id}: #{e.message}"
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
    Rails.logger.debug "WizardImportAlbumsJob: Progress #{processed}/#{@total} (#{progress_percent}%)"
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
