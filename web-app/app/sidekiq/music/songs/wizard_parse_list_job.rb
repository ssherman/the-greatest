class Music::Songs::WizardParseListJob
  include Sidekiq::Job

  def perform(list_id)
    list = Music::Songs::List.find(list_id)

    if list.raw_html.blank?
      handle_error(list, "Cannot parse: raw_html is blank. Please go back and provide HTML content.")
      return
    end

    list.update_wizard_job_status(status: "running", progress: 0)

    list.list_items.unverified.destroy_all

    result = Services::Ai::Tasks::Lists::Music::SongsRawParserTask.new(parent: list).call

    unless result.success?
      handle_error(list, result.error || "Parsing failed")
      return
    end

    songs = result.data[:songs] || result.data["songs"]
    list_items_attrs = songs.map.with_index do |song, index|
      {
        list_id: list.id,
        listable_type: "Music::Song",
        listable_id: nil,
        verified: false,
        position: song[:rank] || (index + 1),
        metadata: {
          "rank" => song[:rank],
          "title" => song[:title],
          "artists" => song[:artists],
          "album" => song[:album],
          "release_year" => song[:release_year]
        },
        created_at: Time.current,
        updated_at: Time.current
      }
    end

    ListItem.insert_all(list_items_attrs) if list_items_attrs.any?

    list.update_wizard_job_status(
      status: "completed",
      progress: 100,
      metadata: {total_items: songs.count, parsed_at: Time.current.iso8601}
    )

    Rails.logger.info "WizardParseListJob completed for list #{list_id}: parsed #{songs.count} items"
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error "WizardParseListJob: List not found - #{e.message}"
    raise
  rescue => e
    Rails.logger.error "WizardParseListJob failed for list #{list_id}: #{e.message}"
    handle_error(list, e.message) if list
    raise
  end

  private

  def handle_error(list, error_message)
    list.update_wizard_job_status(
      status: "failed",
      progress: 0,
      error: error_message
    )
  end
end
