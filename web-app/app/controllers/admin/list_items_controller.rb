class Admin::ListItemsController < Admin::BaseController
  before_action :set_list, only: [:index, :create, :destroy_all, :clear_positions]
  before_action :set_list_item, only: [:edit, :update, :destroy]

  private

  # Override to allow domain-scoped users to manage list items
  # for lists within their domain (e.g., games domain user managing Games::List items)
  def authenticate_admin!
    return if current_user&.admin? || current_user&.editor?

    list = if params[:list_id].present?
      List.find_by(id: params[:list_id])
    elsif params[:id].present?
      ListItem.find_by(id: params[:id])&.list
    end

    domain = list&.type&.split("::")&.first&.downcase
    return if domain.present? && current_user&.can_access_domain?(domain)

    redirect_to domain_root_path, alert: "Access denied. Admin or editor role required."
  end

  public

  def index
    load_list_items
    render layout: false
  end

  def edit
    render Admin::EditListItemFormComponent.new(list_item: @list_item), layout: false
  end

  def create
    @list_item = @list.list_items.build(create_list_item_params)

    if @list_item.save
      @list.reload
      load_list_items
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.replace(
              "flash",
              partial: "admin/shared/flash",
              locals: {flash: {notice: "Item added successfully."}}
            ),
            turbo_stream.replace(
              "list_items_list",
              template: "admin/list_items/index",
              locals: {list: @list, list_items: @list_items, pagy: @pagy}
            ),
            turbo_stream.replace(
              "add_item_to_list_modal",
              Admin::AddItemToListModalComponent.new(list: @list)
            )
          ]
        end
        format.html do
          redirect_to redirect_path, notice: "Item added successfully."
        end
      end
    else
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            "flash",
            partial: "admin/shared/flash",
            locals: {flash: {error: @list_item.errors.full_messages.join(", ")}}
          ), status: :unprocessable_entity
        end
        format.html do
          redirect_to redirect_path, alert: @list_item.errors.full_messages.join(", ")
        end
      end
    end
  end

  def update
    @list = @list_item.list
    update_params = update_list_item_params

    if update_params[:listable_id].present? && update_params[:listable_id].to_s != @list_item.listable_id.to_s
      update_params[:verified] = true
      update_params[:listable_type] = expected_listable_type_for(@list) if @list_item.listable_type.blank?
    end

    if @list_item.update(update_params)
      @list.reload
      load_list_items
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.replace(
              "flash",
              partial: "admin/shared/flash",
              locals: {flash: {notice: "Item updated successfully."}}
            ),
            turbo_stream.replace(
              "list_items_list",
              template: "admin/list_items/index",
              locals: {list: @list, list_items: @list_items, pagy: @pagy}
            )
          ]
        end
        format.html do
          redirect_to redirect_path, notice: "Item updated successfully."
        end
      end
    else
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            "flash",
            partial: "admin/shared/flash",
            locals: {flash: {error: @list_item.errors.full_messages.join(", ")}}
          ), status: :unprocessable_entity
        end
        format.html do
          redirect_to redirect_path, alert: @list_item.errors.full_messages.join(", ")
        end
      end
    end
  end

  def destroy
    @list = @list_item.list
    @list_item.destroy!
    @list.reload
    load_list_items

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace(
            "flash",
            partial: "admin/shared/flash",
            locals: {flash: {notice: "Item removed successfully."}}
          ),
          turbo_stream.replace(
            "list_items_list",
            template: "admin/list_items/index",
            locals: {list: @list, list_items: @list_items, pagy: @pagy}
          ),
          turbo_stream.replace(
            "add_item_to_list_modal",
            Admin::AddItemToListModalComponent.new(list: @list)
          )
        ]
      end
      format.html do
        redirect_to redirect_path, notice: "Item removed successfully."
      end
    end
  end

  def destroy_all
    deleted_count = 0

    ActiveRecord::Base.transaction do
      @list.list_items.find_each do |item|
        item.destroy!
        deleted_count += 1
      end
    end

    redirect_to redirect_path, notice: "#{deleted_count} items deleted from list."
  rescue ActiveRecord::RecordNotDestroyed => e
    redirect_to redirect_path, alert: "Failed to delete items: #{e.message}"
  end

  def clear_positions
    updated_count = @list.list_items.update_all(position: nil)
    redirect_to redirect_path, notice: "Positions cleared for #{updated_count} items."
  end

  private

  def load_list_items
    @pagy, @list_items = pagy(
      @list.list_items.includes(:listable).order(:position),
      limit: 50
    )
  end

  def set_list
    @list = List.find(params[:list_id])
  end

  def set_list_item
    @list_item = ListItem.find(params[:id])
  end

  def create_list_item_params
    params.require(:list_item).permit(:listable_id, :listable_type, :position, :metadata, :verified)
  end

  def update_list_item_params
    permitted = params.require(:list_item).permit(:listable_id, :position, :metadata, :verified)
    permitted.delete(:listable_id) if permitted[:listable_id].blank?
    permitted
  end

  def expected_listable_type_for(list)
    Admin::DomainRouting.list_config(list)&.dig(:listable_type)
  end

  def redirect_path
    Admin::DomainRouting.list_config(@list)&.dig(:path) || music_root_path
  end
end
