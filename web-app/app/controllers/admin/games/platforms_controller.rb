class Admin::Games::PlatformsController < Admin::Games::BaseController
  before_action :set_platform, only: [:show, :edit, :update, :destroy]
  before_action :authorize_platform, only: [:show, :edit, :update, :destroy]

  def index
    authorize Games::Platform
    load_platforms_for_index
  end

  def show
    @platform = Games::Platform
      .includes(game_platforms: [:game])
      .find(params[:id])
  end

  def new
    @platform = Games::Platform.new
    authorize @platform
  end

  def create
    @platform = Games::Platform.new(platform_params)
    authorize @platform

    if @platform.save
      redirect_to admin_games_platform_path(@platform), notice: "Platform created successfully."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @platform.update(platform_params)
      redirect_to admin_games_platform_path(@platform), notice: "Platform updated successfully."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @platform.destroy!
    redirect_to admin_games_platforms_path, notice: "Platform deleted successfully."
  end

  def search
    sanitized = "%#{Games::Platform.sanitize_sql_like(params[:q].to_s)}%"
    platforms = Games::Platform.where("name ILIKE ?", sanitized)
      .order(:name).limit(20)

    render json: platforms.map { |p| {value: p.id, text: "#{p.name}#{" (#{p.abbreviation})" if p.abbreviation.present?}"} }
  end

  private

  def set_platform
    @platform = Games::Platform.find(params[:id])
  end

  def authorize_platform
    authorize @platform
  end

  def load_platforms_for_index
    @platforms = Games::Platform.all

    if params[:q].present?
      sanitized = "%#{Games::Platform.sanitize_sql_like(params[:q])}%"
      @platforms = @platforms.where("name ILIKE ?", sanitized)
    end

    sort_column = sortable_column(params[:sort])
    @platforms = @platforms.order(sort_column)
    @pagy, @platforms = pagy(@platforms, limit: 25)
  end

  def sortable_column(column)
    allowed_columns = {
      "id" => "games_platforms.id",
      "name" => "games_platforms.name",
      "platform_family" => "games_platforms.platform_family",
      "created_at" => "games_platforms.created_at"
    }

    allowed_columns.fetch(column, "games_platforms.name")
  end

  def platform_params
    params.require(:games_platform).permit(:name, :abbreviation, :platform_family)
  end
end
