class Admin::Books::BookAuthorsController < Admin::Books::BaseController
  before_action :set_book_author, only: [:update, :destroy]

  def create
    @book = ::Books::Book.find(params[:book_id])
    authorize @book, :update?, policy_class: ::Books::BookPolicy
    result = Services::Books::BookAuthors::Edit.add(
      book: @book, author_id: book_author_params[:author_id], attrs: edit_attrs(drop_blank_position: true)
    )

    if result.success?
      respond_to do |format|
        format.turbo_stream { render_book_authors("Author added.") }
        format.html { redirect_to admin_books_book_path(@book), notice: "Author added." }
      end
    else
      render_failure(result)
    end
  end

  def update
    @book = @book_author.book
    authorize @book, :update?, policy_class: ::Books::BookPolicy
    result = Services::Books::BookAuthors::Edit.update(
      book: @book, author_id: @book_author.author_id, attrs: edit_attrs(drop_blank_position: false)
    )

    if result.success?
      respond_to do |format|
        format.turbo_stream { render_book_authors("Author updated.") }
        format.html { redirect_to admin_books_book_path(@book), notice: "Author updated." }
      end
    else
      render_failure(result)
    end
  end

  def destroy
    @book = @book_author.book
    authorize @book, :update?, policy_class: ::Books::BookPolicy
    result = Services::Books::BookAuthors::Edit.remove(book: @book, author_id: @book_author.author_id)
    return render_failure(result) unless result.success?

    respond_to do |format|
      format.turbo_stream { render_book_authors("Author removed.") }
      format.html { redirect_to admin_books_book_path(@book), notice: "Author removed." }
    end
  end

  private

  def set_book_author
    @book_author = ::Books::BookAuthor.find(params[:id])
  end

  def book_author_params
    params.require(:books_book_author).permit(:author_id, :role, :position, :credited_as)
  end

  # The permitted role, position and credited_as the form sent. A blank
  # position is dropped on create (the service puts it at the end) and becomes
  # nil on update (it clears the position).
  def edit_attrs(drop_blank_position:)
    attrs = book_author_params.slice(:role, :position, :credited_as).to_h
    if attrs.key?("position")
      if attrs["position"].blank?
        drop_blank_position ? attrs.delete("position") : attrs["position"] = nil
      else
        attrs["position"] = attrs["position"].to_i
      end
    end
    attrs
  end

  def render_failure(result)
    message = result.errors.join(", ")
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace("flash", partial: "admin/shared/flash", locals: {flash: {error: message}}),
          status: :unprocessable_entity
      end
      format.html { redirect_to admin_books_book_path(@book), alert: message }
    end
  end

  def render_book_authors(notice)
    render turbo_stream: [
      turbo_stream.replace("flash", partial: "admin/shared/flash", locals: {flash: {notice: notice}}),
      turbo_stream.replace("book_authors_list", partial: "admin/books/books/book_authors_list", locals: {book: @book})
    ]
  end
end
