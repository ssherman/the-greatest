# frozen_string_literal: true

# Shared actions for wizard list items (verify, metadata update, etc).
# Used by both Music::Songs and Music::Albums ListItemsActionsControllers.
#
# Subclasses must implement:
#   - list_class: Model class for list (e.g., Music::Songs::List)
#   - partials_path: Path prefix for partials (e.g., "admin/music/songs/list_items_actions")
#   - valid_modal_types: Array of valid modal type strings
#   - shared_modal_component_class: Component class for error ID reference
#   - review_step_path: Path to the review step for redirects
#
# Optional overrides:
#   - set_list: Override if custom list loading is needed
#   - set_item: Override if custom item loading is needed
#   - item_actions_for_set_item: Override to add domain-specific actions that need @item loaded
module ListItemsActions
  extend ActiveSupport::Concern

  included do
    before_action :set_list
    before_action :set_item, if: :action_requires_item?
  end

  # GET modal/:modal_type
  # Loads modal content on-demand for the shared modal component.
  # Returns content wrapped in turbo_frame_tag for Turbo Frame replacement.
  def modal
    modal_type = params[:modal_type]

    unless valid_modal_types.include?(modal_type)
      render partial: "#{partials_path}/modals/error",
        locals: {message: "Invalid modal type"}
      return
    end

    render partial: "#{partials_path}/modals/#{modal_type}",
      locals: {item: @item, list: @list}
  end

  # POST verify
  # Marks an item as verified, clearing any AI match invalid flag.
  def verify
    @item.update!(
      verified: true,
      metadata: @item.metadata.except("ai_match_invalid")
    )

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace("item_row_#{@item.id}", partial: "item_row", locals: {item: @item}),
          turbo_stream.replace("review_stats_#{@list.id}", partial: "review_stats", locals: {list: @list}),
          turbo_stream.append("flash_messages", partial: "flash_success", locals: {message: "Item verified"})
        ]
      end
      format.html { redirect_to review_step_path, notice: "Item verified" }
    end
  end

  # DELETE destroy
  # Deletes a single list item.
  def destroy
    @item.destroy!
    render_item_delete_success("Item deleted")
  end

  # POST metadata
  # Updates item metadata from JSON input.
  def metadata
    metadata_json = params.dig(:list_item, :metadata_json)

    begin
      metadata = JSON.parse(metadata_json)
    rescue JSON::ParserError => e
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            shared_modal_component_class::ERROR_ID,
            partial: "error_message",
            locals: {message: "Invalid JSON: #{e.message}"}
          )
        end
        format.html { redirect_to review_step_path, alert: "Invalid JSON: #{e.message}" }
      end
      return
    end

    @item.update!(metadata: metadata)

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace("item_row_#{@item.id}", partial: "item_row", locals: {item: @item}),
          turbo_stream.replace("review_stats_#{@list.id}", partial: "review_stats", locals: {list: @list}),
          turbo_stream.append("flash_messages", partial: "flash_success", locals: {message: "Metadata updated"})
        ]
      end
      format.html { redirect_to review_step_path, notice: "Metadata updated" }
    end
  end

  # Bulk actions

  def bulk_verify
    item_ids = params[:item_ids] || []
    items = @list.list_items.where(id: item_ids)

    items.update_all(verified: true)
    items.each do |item|
      item.update!(metadata: item.metadata.except("ai_match_invalid"))
    end

    redirect_to review_step_path, notice: "#{items.count} items verified"
  end

  def bulk_skip
    item_ids = params[:item_ids] || []
    items = @list.list_items.where(id: item_ids)

    items.each do |item|
      item.update!(verified: false, metadata: item.metadata.merge("skipped" => true))
    end

    redirect_to review_step_path, notice: "#{items.count} items skipped"
  end

  def bulk_delete
    item_ids = params[:item_ids] || []
    deleted_count = @list.list_items.where(id: item_ids).destroy_all.count

    redirect_to review_step_path, notice: "#{deleted_count} items deleted"
  end

  protected

  # Helper to render turbo stream error response
  def render_modal_error(message)
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          shared_modal_component_class::ERROR_ID,
          partial: "error_message",
          locals: {message: message}
        )
      end
      format.html { redirect_to review_step_path, alert: message }
    end
  end

  # Helper to render turbo stream success response with row and stats update
  def render_item_update_success(message)
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace("item_row_#{@item.id}", partial: "item_row", locals: {item: @item}),
          turbo_stream.replace("review_stats_#{@list.id}", partial: "review_stats", locals: {list: @list}),
          turbo_stream.append("flash_messages", partial: "flash_success", locals: {message: message})
        ]
      end
      format.html { redirect_to review_step_path, notice: message }
    end
  end

  # Helper to render turbo stream success response for item deletion
  def render_item_delete_success(message)
    item_id = @item.id
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.remove("item_row_#{item_id}"),
          turbo_stream.replace("review_stats_#{@list.id}", partial: "review_stats", locals: {list: @list}),
          turbo_stream.append("flash_messages", partial: "flash_success", locals: {message: message})
        ]
      end
      format.html { redirect_to review_step_path, notice: message }
    end
  end

  # Override in subclass to add domain-specific actions that need @item loaded
  def item_actions_for_set_item
    [:verify, :destroy, :metadata, :modal]
  end

  private

  def action_requires_item?
    item_actions_for_set_item.include?(action_name.to_sym)
  end

  def set_list
    @list = list_class.find(params[:list_id])
  end

  def set_item
    @item = @list.list_items.includes(listable: :artists).find(params[:id])
  end

  # Abstract methods - subclasses must implement

  def list_class
    raise NotImplementedError, "Subclass must implement #list_class"
  end

  def partials_path
    raise NotImplementedError, "Subclass must implement #partials_path"
  end

  def valid_modal_types
    raise NotImplementedError, "Subclass must implement #valid_modal_types"
  end

  def shared_modal_component_class
    raise NotImplementedError, "Subclass must implement #shared_modal_component_class"
  end

  def review_step_path
    raise NotImplementedError, "Subclass must implement #review_step_path"
  end
end
