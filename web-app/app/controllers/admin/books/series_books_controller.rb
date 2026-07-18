class Admin::Books::SeriesBooksController < Admin::Books::BaseController
  before_action :set_series_book, only: [:update, :destroy, :make_representative]

  def create
    @series = ::Books::Series.find(params[:series_id])
    authorize @series, :update?, policy_class: ::Books::SeriesPolicy
    @series_book = @series.series_books.build(series_book_params)

    if @series_book.save
      respond_to do |format|
        format.turbo_stream { render_series_books("Book added to series.") }
        format.html { redirect_to admin_books_series_path(@series), notice: "Book added to series." }
      end
    else
      respond_to do |format|
        format.turbo_stream { render_association_error(@series_book) }
        format.html { redirect_to admin_books_series_path(@series), alert: @series_book.errors.full_messages.join(", ") }
      end
    end
  end

  def update
    @series = @series_book.series
    authorize @series, :update?, policy_class: ::Books::SeriesPolicy

    if @series_book.update(series_book_params)
      respond_to do |format|
        format.turbo_stream { render_series_books("Series book updated.") }
        format.html { redirect_to admin_books_series_path(@series), notice: "Series book updated." }
      end
    else
      respond_to do |format|
        format.turbo_stream { render_association_error(@series_book) }
        format.html { redirect_to admin_books_series_path(@series), alert: @series_book.errors.full_messages.join(", ") }
      end
    end
  end

  def destroy
    @series = @series_book.series
    authorize @series, :update?, policy_class: ::Books::SeriesPolicy
    @series.update!(representative_book_id: nil) if @series.representative_book_id == @series_book.book_id
    @series_book.destroy!

    respond_to do |format|
      format.turbo_stream { render_series_books("Book removed from series.") }
      format.html { redirect_to admin_books_series_path(@series), notice: "Book removed from series." }
    end
  end

  def make_representative
    @series = @series_book.series
    authorize @series, :update?, policy_class: ::Books::SeriesPolicy
    @series.update!(representative_book_id: @series_book.book_id)

    respond_to do |format|
      format.turbo_stream { render_series_books("Representative book updated.") }
      format.html { redirect_to admin_books_series_path(@series), notice: "Representative book updated." }
    end
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

  def render_association_error(record)
    render turbo_stream: turbo_stream.replace(
      "flash", partial: "admin/shared/flash", locals: {flash: {error: record.errors.full_messages.join(", ")}}
    ), status: :unprocessable_entity
  end
end
