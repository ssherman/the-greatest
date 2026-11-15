class Admin::Books::SeriesBooksController < Admin::Books::BaseController
  before_action :set_series_book, only: [:update, :destroy, :make_representative]

  def create
    @series = ::Books::Series.find(params[:series_id])
    authorize @series, :update?, policy_class: ::Books::SeriesPolicy
    result = Services::Books::SeriesEdits::Membership.add(
      series: @series, book_id: series_book_params[:book_id], attrs: membership_attrs
    )
    respond_with_result(result, "Book added to series.")
  end

  def update
    @series = @series_book.series
    authorize @series, :update?, policy_class: ::Books::SeriesPolicy
    result = Services::Books::SeriesEdits::Membership.update(
      series: @series, book_id: @series_book.book_id, attrs: membership_attrs
    )
    respond_with_result(result, "Series book updated.")
  end

  def destroy
    @series = @series_book.series
    authorize @series, :update?, policy_class: ::Books::SeriesPolicy
    result = Services::Books::SeriesEdits::Membership.remove(series: @series, book_id: @series_book.book_id)
    respond_with_result(result, "Book removed from series.")
  end

  def make_representative
    @series = @series_book.series
    authorize @series, :update?, policy_class: ::Books::SeriesPolicy
    result = Services::Books::SeriesEdits::Update.call(
      series: @series, attrs: {"representative_book_id" => @series_book.book_id}
    )
    respond_with_result(result, "Representative book updated.")
  end

  private

  def set_series_book
    @series_book = ::Books::SeriesBook.find(params[:id])
  end

  def series_book_params
    params.require(:books_series_book).permit(:book_id, :position, :numbered, :position_label)
  end

  def render_series_books(notice)
    render turbo_stream: [
      turbo_stream.replace("flash", partial: "admin/shared/flash", locals: {flash: {notice: notice}}),
      turbo_stream.replace("series_books_list", partial: "admin/books/series/series_books_list", locals: {series: @series})
    ]
  end

  # Form params arrive as strings; the service takes typed values, and only the keys
  # the form actually sent.
  def membership_attrs
    raw = series_book_params
    attrs = {}
    attrs["position"] = raw[:position].presence&.then { |value| BigDecimal(value, exception: false) } if raw.key?(:position)
    attrs["numbered"] = ActiveModel::Type::Boolean.new.cast(raw[:numbered]) if raw.key?(:numbered)
    attrs["position_label"] = raw[:position_label] if raw.key?(:position_label)
    attrs
  end

  def respond_with_result(result, notice)
    if result.success?
      respond_to do |format|
        format.turbo_stream { render_series_books(notice) }
        format.html { redirect_to admin_books_series_path(@series), notice: notice }
      end
    else
      message = result.errors.join(", ")
      respond_to do |format|
        format.turbo_stream { render_error(message) }
        format.html { redirect_to admin_books_series_path(@series), alert: message }
      end
    end
  end

  def render_error(message)
    render turbo_stream: turbo_stream.replace(
      "flash", partial: "admin/shared/flash", locals: {flash: {error: message}}
    ), status: :unprocessable_entity
  end
end
