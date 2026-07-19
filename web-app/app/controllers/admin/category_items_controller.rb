class Admin::CategoryItemsController < Admin::BaseController
  include Admin::DomainScopedAuth

  before_action :set_item, only: [:index, :create]
  before_action :set_category_item, only: [:destroy]

  def index
    @category_items = @item.category_items.includes(:category).order("categories.name")
    render layout: false
  end

  def create
    @category_item = @item.category_items.build(category_item_params)

    if @category_item.save
      @item.reload
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.replace(
              "flash",
              partial: "admin/shared/flash",
              locals: {flash: {notice: "Category added successfully."}}
            ),
            turbo_stream.replace(
              "category_items_list",
              template: "admin/category_items/index",
              locals: {item: @item, category_items: @item.category_items.includes(:category).order("categories.name")}
            ),
            turbo_stream.replace(
              "add_category_modal",
              Admin::AddCategoryModalComponent.new(item: @item)
            )
          ]
        end
        format.html do
          redirect_to redirect_path, notice: "Category added successfully."
        end
      end
    else
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            "flash",
            partial: "admin/shared/flash",
            locals: {flash: {error: @category_item.errors.full_messages.join(", ")}}
          ), status: :unprocessable_entity
        end
        format.html do
          redirect_to redirect_path, alert: @category_item.errors.full_messages.join(", ")
        end
      end
    end
  end

  def destroy
    @item = @category_item.item
    @category_item.destroy!
    @item.reload

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace(
            "flash",
            partial: "admin/shared/flash",
            locals: {flash: {notice: "Category removed successfully."}}
          ),
          turbo_stream.replace(
            "category_items_list",
            template: "admin/category_items/index",
            locals: {item: @item, category_items: @item.category_items.includes(:category).order("categories.name")}
          ),
          turbo_stream.replace(
            "add_category_modal",
            Admin::AddCategoryModalComponent.new(item: @item)
          )
        ]
      end
      format.html do
        redirect_to redirect_path, notice: "Category removed successfully."
      end
    end
  end

  private

  def domain_auth_parent
    if action_name == "destroy"
      CategoryItem.find(params[:id]).item
    else
      Admin::DomainRouting.parent_from_params(params, domain: current_domain)
    end
  end

  def set_item
    @item = Admin::DomainRouting.parent_from_params(params, domain: current_domain)
  end

  def set_category_item
    @category_item = CategoryItem.find(params[:id])
  end

  def category_item_params
    params.require(:category_item).permit(:category_id)
  end

  def redirect_path
    Admin::DomainRouting.path_for(@item) || admin_root_path
  end
end
