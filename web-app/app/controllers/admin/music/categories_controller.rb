class Admin::Music::CategoriesController < Admin::Music::BaseController
  before_action :set_category, only: [:show, :edit, :update, :destroy]

  def index
    @categories = Music::Category.active.includes(:parent)

    if params[:q].present?
      @categories = @categories.search_by_name(params[:q])
    end

    @categories = @categories.order(sortable_column(params[:sort]))
    @pagy, @categories = pagy(@categories, items: 25)
  end

  def show
    @albums_count = @category.albums.count
    @artists_count = @category.artists.count
    @songs_count = @category.songs.count
  end

  def new
    @category = Music::Category.new
  end

  def create
    @category = Music::Category.new(category_params)

    if @category.save
      redirect_to admin_category_path(@category), notice: "Category created successfully."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    # @category loaded by before_action
  end

  def update
    if @category.update(category_params)
      redirect_to admin_category_path(@category), notice: "Category updated successfully."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @category.soft_delete!
    redirect_to admin_categories_path, notice: "Category deleted successfully."
  end

  def search
    categories = Music::Category.active

    if params[:q].present?
      categories = categories.search_by_name(params[:q])
    end

    categories = categories.order(:name).limit(20)

    render json: categories.map { |c| {value: c.id, text: "#{c.name} (#{c.category_type&.titleize || "Unknown"})"} }
  end

  private

  def set_category
    @category = Music::Category.find(params[:id])
  end

  def category_params
    params.require(:music_category).permit(:name, :description, :category_type, :parent_id)
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
