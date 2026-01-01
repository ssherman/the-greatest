class Admin::ListItemsController < Admin::BaseController
  before_action :set_list, only: [:index, :create, :destroy_all]
  before_action :set_list_item, only: [:update, :destroy]

  def index
    @list_items = @list.list_items.includes(:listable).order(:position)
    render layout: false
  end

  def create
    @list_item = @list.list_items.build(create_list_item_params)

    if @list_item.save
      @list.reload
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
              locals: {list: @list, list_items: @list.list_items.includes(:listable).order(:position)}
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

    if @list_item.update(update_list_item_params)
      @list.reload
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
              locals: {list: @list, list_items: @list.list_items.includes(:listable).order(:position)}
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
            locals: {list: @list, list_items: @list.list_items.includes(:listable).order(:position)}
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

  private

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
    params.require(:list_item).permit(:position, :metadata, :verified)
  end

  def redirect_path
    case @list.class.name
    when "Music::Albums::List"
      admin_albums_list_path(@list)
    when "Music::Songs::List"
      admin_songs_list_path(@list)
    else
      music_root_path
    end
  end
end
