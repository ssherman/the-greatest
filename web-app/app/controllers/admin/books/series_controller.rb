class Admin::Books::SeriesController < Admin::Books::BaseController
  before_action :set_series, only: [:show, :edit, :update, :destroy]
  before_action :authorize_series, only: [:show, :edit, :update, :destroy]

  def index
    authorize ::Books::Series
    load_series_for_index
  end

  def show
  end

  def new
    @series = ::Books::Series.new
    authorize @series
  end

  def create
    @series = ::Books::Series.new(series_params)
    authorize @series

    result = Services::Books::SeriesEdits::Create.call(attrs: series_params.to_h)
    if result.success?
      redirect_to admin_books_series_path(result.data), notice: "Series created."
    else
      result.errors.each { |message| @series.errors.add(:base, message) }
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    redirect_to admin_books_series_path(@series), alert: "This series can't be edited." if @series.deleted?
  end

  def update
    result = Services::Books::SeriesEdits::Update.call(series: @series, attrs: series_params.to_h)
    if result.success?
      redirect_to admin_books_series_path(@series), notice: "Series updated."
    else
      result.errors.each { |message| @series.errors.add(:base, message) }
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    result = Services::Books::SeriesEdits::Delete.call(series: @series)
    if result.success?
      redirect_to admin_books_series_index_path, notice: "Series deleted."
    else
      redirect_to admin_books_series_path(@series), alert: result.errors.to_sentence
    end
  end

  private

  def load_series_for_index
    @series_collection = ::Books::Series.active

    if params[:q].present?
      sanitized = "%#{::Books::Series.sanitize_sql_like(params[:q])}%"
      @series_collection = @series_collection.where("title ILIKE ?", sanitized)
    end

    @series_collection = @series_collection.order(sortable_column(params[:sort]))
    @pagy, @series_collection = pagy(@series_collection, limit: 25)
  end

  def sortable_column(column)
    {
      "id" => "books_series.id",
      "title" => "books_series.title",
      "created_at" => "books_series.created_at"
    }.fetch(column, "books_series.title")
  end

  def series_params
    params.require(:books_series).permit(:title)
  end

  def set_series
    @series = ::Books::Series.find(params[:id])
  end

  def authorize_series
    authorize @series
  end
end
