class Admin::CategoriesBaseController < Admin::BaseController
  before_action :set_category, only: [:show, :edit, :update, :destroy]
  before_action :authorize_category, only: [:show, :edit, :update, :destroy]

  helper_method :domain_config

  def index
    authorize model_class
    @categories = model_class.active.includes(:parent)

    if params[:q].present?
      @categories = @categories.search_by_name(params[:q])
    end

    @categories = @categories.order(sortable_column(params[:sort]))
    @pagy, @categories = pagy(@categories, limit: 25)
  end

  def show
    load_show_stats
  end

  def new
    @category = model_class.new
    authorize @category
  end

  def create
    @category = model_class.new(category_params)
    authorize @category

    if @category.save
      redirect_to category_path(@category), notice: "Category created successfully."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @category.update(category_params)
      redirect_to category_path(@category), notice: "Category updated successfully."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @category.soft_delete!
    redirect_to categories_path, notice: "Category deleted successfully."
  end

  def search
    categories = model_class.active

    if params[:q].present?
      categories = categories.search_by_name(params[:q])
    end

    categories = categories.order(:name).limit(20)

    render json: categories.map { |c| {value: c.id, text: "#{c.name} (#{c.category_type&.titleize || "Unknown"})"} }
  end

  private

  def set_category
    @category = model_class.find(params[:id])
  end

  def authorize_category
    authorize @category
  end

  def category_params
    params.require(param_key).permit(:name, :description, :category_type, :parent_id)
  end

  def sortable_column(column)
    allowed_columns = {
      "name" => "categories.name",
      "category_type" => "categories.category_type",
      "item_count" => "categories.item_count DESC"
    }

    allowed_columns.fetch(column, "categories.name")
  end

  def domain_config
    {
      model_class: model_class,
      category_path_proc: method(:category_path),
      categories_path: categories_path,
      new_category_path: new_category_path,
      edit_category_path_proc: method(:edit_category_path),
      domain_label: domain_label,
      subtitle: subtitle
    }
  end

  protected

  def model_class
    raise NotImplementedError, "Subclass must implement model_class"
  end

  def param_key
    raise NotImplementedError, "Subclass must implement param_key"
  end

  def category_path(category)
    raise NotImplementedError, "Subclass must implement category_path"
  end

  def categories_path
    raise NotImplementedError, "Subclass must implement categories_path"
  end

  def new_category_path
    raise NotImplementedError, "Subclass must implement new_category_path"
  end

  def edit_category_path(category)
    raise NotImplementedError, "Subclass must implement edit_category_path"
  end

  def domain_label
    raise NotImplementedError, "Subclass must implement domain_label"
  end

  def subtitle
    raise NotImplementedError, "Subclass must implement subtitle"
  end

  def load_show_stats
    raise NotImplementedError, "Subclass must implement load_show_stats"
  end
end
