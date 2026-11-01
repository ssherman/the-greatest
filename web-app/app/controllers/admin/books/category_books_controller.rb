# The read-only "Books" frame on a category's admin page, ranked books first.
# Paginated because the big categories (Fiction, Nonfiction) hold tens of
# thousands of books.
class Admin::Books::CategoryBooksController < Admin::Books::BaseController
  PER_PAGE = 50

  def index
    @category = ::Books::Category.find(params[:category_id])
    authorize @category, :show?
    book_ids = @category.category_items.where(item_type: "Books::Book").select(:item_id)
    books = ::Books::Book.where(id: book_ids).ordered_by_primary_rank.includes(:authors)
    @pagy, @books = pagy(books, limit: PER_PAGE)
    render layout: false
  end
end
