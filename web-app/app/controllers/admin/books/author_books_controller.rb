# The read-only "Books" frame on an author's admin page: every book the author
# is credited on, ranked books first. Credits are edited from the book's page.
class Admin::Books::AuthorBooksController < Admin::Books::BaseController
  PER_PAGE = 50

  def index
    @author = ::Books::Author.find(params[:author_id])
    authorize @author, :show?
    books = ::Books::Book.where(id: @author.book_authors.select(:book_id)).ordered_by_primary_rank
    @pagy, @books = pagy(books, limit: PER_PAGE)
    @role_by_book = @author.book_authors.where(book_id: @books.map(&:id)).pluck(:book_id, :role).to_h
    render layout: false
  end
end
