class Admin::Books::BookAuthorsController < Admin::Books::BaseController
  before_action :set_book_author, only: [:update, :destroy]

  def create
    @book = ::Books::Book.find(params[:book_id])
    authorize @book, :update?, policy_class: ::Books::BookPolicy
    @book_author = @book.book_authors.build(book_author_params)

    if @book_author.save
      respond_to do |format|
        format.turbo_stream { render_book_authors("Author added.") }
        format.html { redirect_to admin_books_book_path(@book), notice: "Author added." }
      end
    else
      respond_to do |format|
        format.turbo_stream { render_association_error(@book_author) }
        format.html { redirect_to admin_books_book_path(@book), alert: @book_author.errors.full_messages.join(", ") }
      end
    end
  end

  def update
    @book = @book_author.book
    authorize @book, :update?, policy_class: ::Books::BookPolicy

    if @book_author.update(book_author_params)
      respond_to do |format|
        format.turbo_stream { render_book_authors("Author updated.") }
        format.html { redirect_to admin_books_book_path(@book), notice: "Author updated." }
      end
    else
      respond_to do |format|
        format.turbo_stream { render_association_error(@book_author) }
        format.html { redirect_to admin_books_book_path(@book), alert: @book_author.errors.full_messages.join(", ") }
      end
    end
  end

  def destroy
    @book = @book_author.book
    authorize @book, :update?, policy_class: ::Books::BookPolicy
    @book_author.destroy!

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

  def render_book_authors(notice)
    render turbo_stream: [
      turbo_stream.replace("flash", partial: "admin/shared/flash", locals: {flash: {notice: notice}}),
      turbo_stream.replace("book_authors_list", partial: "admin/books/books/book_authors_list", locals: {book: @book})
    ]
  end

  def render_association_error(record)
    render turbo_stream: turbo_stream.replace(
      "flash", partial: "admin/shared/flash", locals: {flash: {error: record.errors.full_messages.join(", ")}}
    ), status: :unprocessable_entity
  end
end
