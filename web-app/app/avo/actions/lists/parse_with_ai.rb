class Avo::Actions::Lists::ParseWithAi < Avo::BaseAction
  self.name = "Parse with AI"
  self.message = "This will parse the selected list(s) with AI in the background."
  self.confirm_button_label = "Parse with AI"

  def handle(query:, fields:, current_user:, resource:, **args)
    # Extract list IDs from the query
    list_ids = query.pluck(:id)

    # Enqueue a separate job for each list
    list_ids.each do |list_id|
      ParseListWithAiJob.perform_async(list_id)
    end

    # Return success message
    succeed "#{list_ids.length} list(s) queued for AI parsing. Each list will be processed in a separate background job."
  end
end
