class Music::Songs::WizardImportSongsJob
  include Sidekiq::Job

  PROGRESS_UPDATE_INTERVAL = 10

  def perform(list_id)
    @list = Music::Songs::List.find(list_id)
    @last_progress_update = Time.current
    import_source = @list.wizard_state&.dig("import_source")

    if import_source == "musicbrainz_series"
      import_from_series
    else
      import_from_custom_html
    end
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error "WizardImportSongsJob: List not found - #{e.message}"
    raise
  rescue => e
    Rails.logger.error "WizardImportSongsJob failed for list #{list_id}: #{e.message}"
    handle_error(e.message) if @list
    raise
  end

  private

  def import_from_series
    @list.update_wizard_step_status(step: "import", status: "running", progress: 0, metadata: {
      "import_source" => "musicbrainz_series"
    })

    result = DataImporters::Music::Lists::ImportSongsFromMusicbrainzSeries.call(list: @list)

    if result[:success]
      verified_count = mark_series_items_as_verified

      @list.update_wizard_step_status(
        step: "import",
        status: "completed",
        progress: 100,
        metadata: {
          "import_source" => "musicbrainz_series",
          "imported_count" => result[:imported_count],
          "total_count" => result[:total_count],
          "failed_count" => result[:total_count] - result[:imported_count],
          "list_items_created" => result[:imported_count],
          "verified_count" => verified_count,
          "imported_at" => Time.current.iso8601
        }
      )

      Rails.logger.info "WizardImportSongsJob (series) completed for list #{@list.id}: " \
        "#{result[:imported_count]} of #{result[:total_count]} imported, #{verified_count} verified"
    else
      handle_error(result[:message] || "Series import failed")
    end
  end

  def import_from_custom_html
    @items_to_import = items_needing_import
    @total = @items_to_import.count

    if @total.zero?
      complete_with_no_items
      return
    end

    @list.update_wizard_step_status(step: "import", status: "running", progress: 0, metadata: {
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
      update_progress(index + 1) if should_update_progress?(index)
    end

    complete_job
  end

  def items_needing_import
    @list.list_items
      .where(listable_id: nil)
      .where("metadata->>'mb_recording_id' IS NOT NULL")
      .where("metadata->>'imported_at' IS NULL")
      .where("metadata->>'ai_match_invalid' IS NULL OR metadata->>'ai_match_invalid' != 'true'")
      .ordered
  end

  def import_item(item)
    mb_id = item.metadata["mb_recording_id"]

    begin
      result = DataImporters::Music::Song::Importer.call(musicbrainz_recording_id: mb_id)

      if result.success? && result.item&.persisted?
        item.update!(
          listable: result.item,
          verified: true,
          metadata: item.metadata.merge(
            "imported_at" => Time.current.iso8601,
            "imported_song_id" => result.item.id
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
      Rails.logger.error "WizardImportSongsJob: Failed to import item #{item.id}: #{e.message}"
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

  def mark_series_items_as_verified
    @list.list_items.where(verified: false).where.not(listable_id: nil).update_all(verified: true)
  end

  def should_update_progress?(index)
    return true if (index + 1) == @total
    return true if (index + 1) % PROGRESS_UPDATE_INTERVAL == 0
    return true if Time.current - @last_progress_update >= 5.seconds
    false
  end

  def update_progress(processed)
    progress_percent = ((processed.to_f / @total) * 100).round

    @list.update_wizard_step_status(
      step: "import",
      status: "running",
      progress: progress_percent,
      metadata: {
        "import_source" => "custom_html",
        "processed_items" => processed,
        "total_items" => @total,
        "imported_count" => @stats[:imported],
        "skipped_count" => @stats[:skipped],
        "failed_count" => @stats[:failed]
      }
    )

    @last_progress_update = Time.current
    Rails.logger.debug "WizardImportSongsJob: Progress #{processed}/#{@total} (#{progress_percent}%)"
  end

  def complete_job
    @list.update_wizard_step_status(
      step: "import",
      status: "completed",
      progress: 100,
      metadata: {
        "import_source" => "custom_html",
        "processed_items" => @total,
        "total_items" => @total,
        "imported_count" => @stats[:imported],
        "skipped_count" => @stats[:skipped],
        "failed_count" => @stats[:failed],
        "errors" => @stats[:errors],
        "imported_at" => Time.current.iso8601
      }
    )

    Rails.logger.info "WizardImportSongsJob completed for list #{@list.id}: " \
      "#{@stats[:imported]} imported, #{@stats[:skipped]} skipped, #{@stats[:failed]} failed"
  end

  def complete_with_no_items
    @list.update_wizard_step_status(
      step: "import",
      status: "completed",
      progress: 100,
      metadata: {
        "import_source" => "custom_html",
        "processed_items" => 0,
        "total_items" => 0,
        "imported_count" => 0,
        "skipped_count" => 0,
        "failed_count" => 0,
        "errors" => [],
        "imported_at" => Time.current.iso8601
      }
    )

    Rails.logger.info "WizardImportSongsJob completed for list #{@list.id}: No items to import"
  end

  def handle_error(error_message)
    @list.update_wizard_step_status(
      step: "import",
      status: "failed",
      progress: 0,
      error: error_message
    )
  end
end
