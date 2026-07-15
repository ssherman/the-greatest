class Admin::Books::BooksController < Admin::Books::BaseController
  def index
    authorize ::Books::Book
    load_books_for_index
  end

  def search
    results = ::Search::Books::Search::BookAutocomplete.call(params[:q], size: 20)
    book_ids = results.map { |r| r[:id].to_i }

    if book_ids.empty?
      render json: []
      return
    end

    books = ::Books::Book.where(id: book_ids).in_order_of(:id, book_ids)
    render json: books.map { |b| {value: b.id, text: autocomplete_label(b)} }
  end

  private

  def set_book
    @book = ::Books::Book.find(params[:id])
  end

  def authorize_book
    authorize @book
  end

  def load_books_for_index
    if params[:q].present?
      results = ::Search::Books::Search::BookGeneral.call(params[:q], size: 1000)
      book_ids = results.map { |r| r[:id].to_i }

      @books = if book_ids.empty?
        ::Books::Book.none
      else
        ::Books::Book.where(id: book_ids).includes(:authors).in_order_of(:id, book_ids)
      end
    else
      @books = ::Books::Book.all.includes(:authors).order(sortable_column(params[:sort]))
    end

    @pagy, @books = pagy(@books, limit: 25)
  end

  def sortable_column(column)
    {
      "id" => "books_books.id",
      "title" => "books_books.title",
      "first_published_year" => "books_books.first_published_year",
      "book_kind" => "books_books.book_kind",
      "created_at" => "books_books.created_at"
    }.fetch(column, "books_books.title")
  end

  def autocomplete_label(book)
    year = book.first_published_year
    "#{book.title}#{" (#{year})" if year.present?}"
  end
end
