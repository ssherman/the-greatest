# frozen_string_literal: true

# Base class for wizard parse jobs.
# Parses raw HTML to extract list items using AI.
#
# Supports optional batch processing for large plain text lists (1000+ items).
# When batch_mode is enabled in wizard_state, splits content by lines and
# processes in batches of 100 to ensure all items are captured.
#
# Subclasses must implement:
#   - list_class: Model class for list (e.g., Music::Songs::List)
#   - parser_task_class: AI task class for parsing
#   - data_key: Key in result data (e.g., :songs, :albums)
#   - listable_type: Type string for list items (e.g., "Music::Song")
#   - build_metadata(item, index): Builds metadata hash from parsed item
#
class BaseWizardParseListJob
  include Sidekiq::Job

  def perform(list_id)
    @list = list_class.find(list_id)

    if @list.raw_content.blank?
      handle_error("Cannot parse: raw_content is blank. Please go back and provide content.")
      return
    end

    @list.wizard_manager.update_step_status!(step: "parse", status: "running", progress: 0)

    @list.list_items.unverified.destroy_all

    if batch_mode?
      perform_batched_parse
    else
      perform_single_parse
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

  # Check if batch mode is enabled in wizard_state
  def batch_mode?
    @list.wizard_state&.dig("batch_mode") == true
  end

  # Split content into batches of lines, filtering empty lines globally first
  def split_into_batches(content, batch_size: 100)
    lines = content.split("\n").reject { |line| line.strip.empty? }
    lines.each_slice(batch_size).map { |batch| batch.join("\n") }
  end

  # Process content in a single AI call (original behavior)
  def perform_single_parse
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
        metadata: sanitize_metadata(build_metadata(item)),
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

    Rails.logger.info "#{self.class.name} completed for list #{@list.id}: parsed #{items.count} items"
  end

  # Process content in batches of lines for large lists
  def perform_batched_parse
    batches = split_into_batches(@list.simplified_content)
    all_items_attrs = []
    current_position = 0

    batches.each_with_index do |batch_content, batch_index|
      # Parse this batch (ai_chat associated with @list, content overridden for batch)
      result = parser_task_class.new(parent: @list, content: batch_content).call

      unless result.success?
        error_msg = "Parsing failed on batch #{batch_index + 1}: #{result.error}"
        handle_error(error_msg)
        raise error_msg
      end

      # Extract items for this batch
      items = result.data[data_key] || result.data[data_key.to_s]

      # Map items with strictly sequential positions (ignore AI ranks in batch mode)
      batch_items_attrs = items.map do |item|
        current_position += 1
        {
          list_id: @list.id,
          listable_type: listable_type,
          listable_id: nil,
          verified: false,
          position: current_position,
          metadata: sanitize_metadata(build_metadata(item)),
          created_at: Time.current,
          updated_at: Time.current
        }
      end

      all_items_attrs.concat(batch_items_attrs)

      # Update progress
      @list.wizard_manager.update_step_status!(
        step: "parse",
        status: "running",
        progress: ((batch_index + 1).to_f / batches.size * 100).to_i,
        metadata: {
          batches_completed: batch_index + 1,
          total_batches: batches.size,
          items_processed: all_items_attrs.size
        }
      )
    end

    # Insert all items at once (atomic operation)
    ListItem.insert_all(all_items_attrs) if all_items_attrs.any?

    # Mark step as completed
    @list.wizard_manager.update_step_status!(
      step: "parse",
      status: "completed",
      progress: 100,
      metadata: {
        total_items: all_items_attrs.count,
        parsed_at: Time.current.iso8601,
        batched: true,
        total_batches: batches.size
      }
    )

    Rails.logger.info "#{self.class.name} completed for list #{@list.id}: parsed #{all_items_attrs.count} items in #{batches.size} batches"
  end

  # Remove null bytes (\u0000) from strings in metadata.
  # PostgreSQL JSONB columns cannot store null bytes.
  def sanitize_metadata(hash)
    hash.transform_values do |value|
      case value
      when String
        value.delete("\u0000")
      when Hash
        sanitize_metadata(value)
      when Array
        value.map { |v| v.is_a?(String) ? v.delete("\u0000") : v }
      else
        value
      end
    end
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
