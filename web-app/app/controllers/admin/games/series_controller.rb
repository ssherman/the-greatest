class Admin::Games::SeriesController < Admin::Games::BaseController
  before_action :set_series, only: [:show, :edit, :update, :destroy]
  before_action :authorize_series, only: [:show, :edit, :update, :destroy]

  def index
    authorize Games::Series
    load_series_for_index
  end

  def show
    @series = Games::Series
      .includes(games: [:platforms, :companies])
      .find(params[:id])
  end

  def new
    @series = Games::Series.new
    authorize @series
  end

  def create
    @series = Games::Series.new(series_params)
    authorize @series

    if @series.save
      redirect_to admin_games_series_path(@series), notice: "Series created successfully."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @series.update(series_params)
      redirect_to admin_games_series_path(@series), notice: "Series updated successfully."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @series.destroy!
    redirect_to admin_games_series_index_path, notice: "Series deleted successfully."
  end

  def search
    sanitized = "%#{Games::Series.sanitize_sql_like(params[:q].to_s)}%"
    series = Games::Series.where("name ILIKE ?", sanitized)
      .order(:name).limit(20)

    render json: series.map { |s| {value: s.id, text: s.name} }
  end

  private

  def set_series
    @series = Games::Series.find(params[:id])
  end

  def authorize_series
    authorize @series
  end

  def load_series_for_index
    @series_collection = Games::Series.all

    if params[:q].present?
      sanitized = "%#{Games::Series.sanitize_sql_like(params[:q])}%"
      @series_collection = @series_collection.where("name ILIKE ?", sanitized)
    end

    sort_column = sortable_column(params[:sort])
    @series_collection = @series_collection.order(sort_column)
    @pagy, @series_collection = pagy(@series_collection, limit: 25)
  end

  def sortable_column(column)
    allowed_columns = {
      "id" => "games_series.id",
      "name" => "games_series.name",
      "created_at" => "games_series.created_at"
    }

    allowed_columns.fetch(column, "games_series.name")
  end

  def series_params
    params.require(:games_series).permit(:name, :description)
  end
end
