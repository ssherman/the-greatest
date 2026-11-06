# The read-only "Identifiers" frame on a book's admin page. Identifiers are
# written programmatically (importers, the verification pass), so there is no
# create/edit/delete here. Paginated because a few books hold thousands.
class Admin::Books::IdentifiersController < Admin::Books::BaseController
  PER_PAGE = 50

  def index
    @book = ::Books::Book.find(params[:book_id])
    authorize @book, :show?
    @pagy, @identifiers = pagy(@book.identifiers.order(:identifier_type, :value, :id), limit: PER_PAGE)
    render layout: false
  end
end
