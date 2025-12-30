# frozen_string_literal: true

# Base class for wizard parse jobs.
# Parses raw HTML to extract list items using AI.
#
# Subclasses must implement:
#   - list_class: Model class for list (e.g., Music::Songs::List)
#   - parser_task_class: AI task class for parsing
#   - data_key: Key in result data (e.g., :songs, :albums)
#   - listable_type: Type string for list items (e.g., "Music::Song")
#   - build_metadata(item, index): Builds metadata hash from parsed item
#
class Music::BaseWizardParseListJob
  include Sidekiq::Job

  def perform(list_id)
    @list = list_class.find(list_id)

    if @list.raw_html.blank?
      handle_error("Cannot parse: raw_html is blank. Please go back and provide HTML content.")
      return
    end

    @list.wizard_manager.update_step_status!(step: "parse", status: "running", progress: 0)

    @list.list_items.unverified.destroy_all

    result = parser_task_class.new(parent: @list).call

    unless result.success?
      handle_error(result.error || "Parsing failed")
      return
    end

    items = result.data[data_key] || result.data[data_key.to_s]
    list_items_attrs = items.map.with_index do |item, index|
      {
        list_id: @list.id,
        listable_type: listable_type,
        listable_id: nil,
        verified: false,
        position: item[:rank] || (index + 1),
        metadata: build_metadata(item),
        created_at: Time.current,
        updated_at: Time.current
      }
    end

    ListItem.insert_all(list_items_attrs) if list_items_attrs.any?

    @list.wizard_manager.update_step_status!(
      step: "parse",
      status: "completed",
      progress: 100,
      metadata: {total_items: items.count, parsed_at: Time.current.iso8601}
    )

    Rails.logger.info "#{self.class.name} completed for list #{list_id}: parsed #{items.count} items"
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

  def parser_task_class
    raise NotImplementedError, "Subclass must implement #parser_task_class"
  end

  def data_key
    raise NotImplementedError, "Subclass must implement #data_key"
  end

  def listable_type
    raise NotImplementedError, "Subclass must implement #listable_type"
  end

  def build_metadata(item)
    raise NotImplementedError, "Subclass must implement #build_metadata"
  end

  def handle_error(error_message)
    @list.wizard_manager.update_step_status!(
      step: "parse",
      status: "failed",
      progress: 0,
      error: error_message
    )
  end
end
