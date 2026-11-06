# The owner's place to check every alternate-title decision. `index` is the
# lazy card on a book's admin page; `review` lists the rows the AI review sent
# to `review` across all books. Members go through Writer.decide, which records
# the admin and keeps the AI's verdict.
class Admin::Books::AlternateTitlesController < Admin::Books::BaseController
  PER_PAGE = 50
  SOURCES = ::AlternateTitle.sources.keys.freeze

  before_action :require_domain_write!, only: [:keep, :remove, :restore]
  before_action :set_row, only: [:keep, :remove, :restore]

  helper_method :source_filter

  def index
    @book = ::Books::Book.find(params[:book_id])
    authorize @book, :show?
    rows = book_rows(@book)
    @total = rows.count
    @pagy, @rows = pagy(rows.includes(:ai_chat, :decided_by_user, titleable: [:authors, :original_language]).order(:id), limit: PER_PAGE)
    render layout: false
  end

  def review
    scope = book_rows.review
    scope = scope.where(source: source_filter) if source_filter
    @pagy, @rows = pagy(scope.includes(:ai_chat, :decided_by_user, titleable: [:authors, :original_language]).order(:id), limit: PER_PAGE)
  end

  def keep
    decide(:kept) { @row.review? }
  end

  def remove
    decide(:removed) { @row.kept? || @row.review? }
  end

  def restore
    decide(:kept) { @row.removed? }
  end

  private

  def book_rows(book = nil)
    scope = ::AlternateTitle.where(titleable_type: "Books::Book")
    book ? scope.where(titleable_id: book.id) : scope
  end

  def set_row
    @row = book_rows.find(params[:id])
  end

  def source_filter
    params[:source] if SOURCES.include?(params[:source])
  end

  def decide(status)
    if yield
      ::Services::AlternateTitles::Writer.decide(row: @row, status: status, user: current_user)
      redirect_back_or_to admin_books_book_path(@row.titleable), notice: "Alternate title #{status}."
    else
      redirect_back_or_to admin_books_book_path(@row.titleable), alert: "That title is #{@row.status}; #{action_name} does not apply."
    end
  end
end
