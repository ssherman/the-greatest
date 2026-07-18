class Admin::Books::SeriesController < Admin::Books::BaseController
  before_action :set_series, only: [:show]
  before_action :authorize_series, only: [:show]

  def index
    authorize ::Books::Series
    load_series_for_index
  end

  def show
  end

  private

  def load_series_for_index
    @series_collection = ::Books::Series.all

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

  def set_series
    @series = ::Books::Series.find(params[:id])
  end

  def authorize_series
    authorize @series
  end
end
