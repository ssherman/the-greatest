class Admin::Books::BookRelationshipsController < Admin::Books::BaseController
  before_action :set_book_relationship, only: [:update, :destroy]

  def create
    @book = ::Books::Book.find(params[:book_id])
    authorize @book, :update?, policy_class: ::Books::BookPolicy
    @book_relationship = @book.book_relationships.build(book_relationship_params)

    if @book_relationship.save
      respond_to do |format|
        format.turbo_stream { render_book_relationships("Related book added.") }
        format.html { redirect_to admin_books_book_path(@book), notice: "Related book added." }
      end
    else
      respond_to do |format|
        format.turbo_stream { render_association_error(@book_relationship) }
        format.html { redirect_to admin_books_book_path(@book), alert: @book_relationship.errors.full_messages.join(", ") }
      end
    end
  end

  def update
    @book = @book_relationship.book
    authorize @book, :update?, policy_class: ::Books::BookPolicy

    if @book_relationship.update(book_relationship_params)
      respond_to do |format|
        format.turbo_stream { render_book_relationships("Relationship updated.") }
        format.html { redirect_to admin_books_book_path(@book), notice: "Relationship updated." }
      end
    else
      respond_to do |format|
        format.turbo_stream { render_association_error(@book_relationship) }
        format.html { redirect_to admin_books_book_path(@book), alert: @book_relationship.errors.full_messages.join(", ") }
      end
    end
  end

  def destroy
    @book = @book_relationship.book
    authorize @book, :update?, policy_class: ::Books::BookPolicy
    @book_relationship.destroy!

    respond_to do |format|
      format.turbo_stream { render_book_relationships("Related book removed.") }
      format.html { redirect_to admin_books_book_path(@book), notice: "Related book removed." }
    end
  end

  private

  def set_book_relationship
    @book_relationship = ::Books::BookRelationship.find(params[:id])
  end

  def book_relationship_params
    params.require(:books_book_relationship).permit(:related_book_id, :relation_type)
  end

  def render_book_relationships(notice)
    render turbo_stream: [
      turbo_stream.replace("flash", partial: "admin/shared/flash", locals: {flash: {notice: notice}}),
      turbo_stream.replace("book_relationships_list", partial: "admin/books/books/book_relationships_list", locals: {book: @book})
    ]
  end

  def render_association_error(record)
    render turbo_stream: turbo_stream.replace(
      "flash", partial: "admin/shared/flash", locals: {flash: {error: record.errors.full_messages.join(", ")}}
    ), status: :unprocessable_entity
  end
end
