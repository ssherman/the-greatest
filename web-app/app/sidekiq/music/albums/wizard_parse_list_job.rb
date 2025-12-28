class Music::Albums::WizardParseListJob
  include Sidekiq::Job

  def perform(list_id)
    list = Music::Albums::List.find(list_id)

    if list.raw_html.blank?
      handle_error(list, "Cannot parse: raw_html is blank. Please go back and provide HTML content.")
      return
    end

    list.wizard_manager.update_step_status!(step: "parse", status: "running", progress: 0)

    list.list_items.unverified.destroy_all

    result = Services::Ai::Tasks::Lists::Music::AlbumsRawParserTask.new(parent: list).call

    unless result.success?
      handle_error(list, result.error || "Parsing failed")
      return
    end

    albums = result.data[:albums] || result.data["albums"]
    list_items_attrs = albums.map.with_index do |album, index|
      {
        list_id: list.id,
        listable_type: "Music::Album",
        listable_id: nil,
        verified: false,
        position: album[:rank] || (index + 1),
        metadata: {
          "rank" => album[:rank],
          "title" => album[:title],
          "artists" => album[:artists],
          "release_year" => album[:release_year]
        },
        created_at: Time.current,
        updated_at: Time.current
      }
    end

    ListItem.insert_all(list_items_attrs) if list_items_attrs.any?

    list.wizard_manager.update_step_status!(
      step: "parse",
      status: "completed",
      progress: 100,
      metadata: {total_items: albums.count, parsed_at: Time.current.iso8601}
    )

    Rails.logger.info "WizardParseListJob completed for list #{list_id}: parsed #{albums.count} items"
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
    list.wizard_manager.update_step_status!(
      step: "parse",
      status: "failed",
      progress: 0,
      error: error_message
    )
  end
end
