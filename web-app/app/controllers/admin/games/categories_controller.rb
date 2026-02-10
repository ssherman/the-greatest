class Admin::Games::CategoriesController < Admin::Games::BaseController
  before_action :set_category, only: [:show, :edit, :update, :destroy]
  before_action :authorize_category, only: [:show, :edit, :update, :destroy]

  def index
    authorize Games::Category
    @categories = Games::Category.active.includes(:parent)

    if params[:q].present?
      @categories = @categories.search_by_name(params[:q])
    end

    @categories = @categories.order(sortable_column(params[:sort]))
    @pagy, @categories = pagy(@categories, limit: 25)
  end

  def show
    @games_count = @category.games.count
  end

  def new
    @category = Games::Category.new
    authorize @category
  end

  def create
    @category = Games::Category.new(category_params)
    authorize @category

    if @category.save
      redirect_to admin_games_category_path(@category), notice: "Category created successfully."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @category.update(category_params)
      redirect_to admin_games_category_path(@category), notice: "Category updated successfully."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @category.soft_delete!
    redirect_to admin_games_categories_path, notice: "Category deleted successfully."
  end

  def search
    categories = Games::Category.active

    if params[:q].present?
      categories = categories.search_by_name(params[:q])
    end

    categories = categories.order(:name).limit(20)

    render json: categories.map { |c| {value: c.id, text: "#{c.name} (#{c.category_type&.titleize || "Unknown"})"} }
  end

  private

  def set_category
    @category = Games::Category.find(params[:id])
  end

  def authorize_category
    authorize @category
  end

  def category_params
    params.require(:games_category).permit(:name, :description, :category_type, :parent_id)
  end

  def sortable_column(column)
    allowed_columns = {
      "name" => "categories.name",
      "category_type" => "categories.category_type",
      "item_count" => "categories.item_count DESC"
    }

    allowed_columns.fetch(column, "categories.name")
  end
end
