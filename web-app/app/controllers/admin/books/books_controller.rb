class Admin::Books::BooksController < Admin::Books::BaseController
  before_action :set_book, only: [:show, :edit, :update, :destroy, :execute_action]
  before_action :authorize_book, only: [:show, :edit, :update, :destroy, :execute_action]

  def index
    authorize ::Books::Book
    load_books_for_index
  end

  def search
    results = ::Search::Books::Search::BookAutocomplete.call(params[:q], size: 20, book_kind: nil, include_provisional: true)
    book_ids = results.map { |r| r[:id].to_i }
    book_ids.delete(params[:exclude_id].to_i) if params[:exclude_id].present?

    if book_ids.empty?
      render json: []
      return
    end

    books = ::Books::Book.where(id: book_ids).in_order_of(:id, book_ids)
    render json: books.map { |b| {value: b.id, text: autocomplete_label(b)} }
  end

  def show
  end

  def new
    @book = ::Books::Book.new
    authorize @book
  end

  def create
    @book = ::Books::Book.new
    assign_book_attributes(@book)
    authorize @book

    if save_with_titles(@book)
      redirect_to admin_books_book_path(@book), notice: "Book created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    assign_book_attributes(@book)

    if save_with_titles(@book)
      redirect_to admin_books_book_path(@book), notice: "Book updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    ::Books::Book.transaction do |transaction|
      urls = Services::Books::ReadingGoals::DestructionInvalidator.for_book(book: @book)
      @book.destroy!
      transaction.after_commit do
        ::Books::ReadingGoals::PurgeCachedPagesJob.perform_async("books", urls) if urls.any?
      end
    end
    redirect_to admin_books_books_path, notice: "Book deleted."
  end

  def execute_action
    fields_hash = params.except(:controller, :action, :id, :action_name)

    validate_action_name!
    action_class = "Actions::Admin::Books::#{params[:action_name]}".constantize
    # The delete gate for destructive actions. execute_action? itself only
    # requires write access, because this endpoint is shared.
    authorize @book, :destroy? if action_class.destructive?
    result = action_class.call(
      user: current_user,
      models: [@book],
      fields: fields_hash
    )

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "flash",
          partial: "admin/shared/flash",
          locals: {result: result}
        )
      end
      format.html { redirect_to admin_books_book_path(@book), notice: result.message }
    end
  end

  private

  def allowed_action_names
    %w[MergeBook EnrichBook]
  end

  def set_book
    @book = ::Books::Book.find(params[:id])
  end

  def authorize_book
    authorize @book
  end

  def load_books_for_index
    if params[:q].present?
      results = ::Search::Books::Search::BookGeneral.call(params[:q], size: 1000, book_kind: nil, include_provisional: true)
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

  def book_params
    params.require(:books_book).permit(
      :title, :subtitle, :sort_title,
      :first_published_year, :book_kind, :original_language_id
    )
  end

  def assign_book_attributes(record)
    record.assign_attributes(book_params)
    @submitted_titles = submitted_alternate_titles
  end

  # nil when the form did not post the key, so another form posting to update
  # leaves the titles alone. Never permitted through book_params: the titles
  # are written through the alternate_titles table, not assigned.
  def submitted_alternate_titles
    return unless params[:books_book].respond_to?(:key?) && params[:books_book].key?(:alternate_titles)
    Array(params[:books_book][:alternate_titles]).map { |t| t.to_s.strip }.reject(&:blank?)
  end

  # The book save and the title rows commit together (create needs the id
  # first). A validation failure writes nothing and leaves the submitted
  # titles in @submitted_titles so the re-rendered form shows them.
  def save_with_titles(record)
    titles = @submitted_titles
    saved = false
    ::Books::Book.transaction do
      unless record.save
        raise ActiveRecord::Rollback
      end
      if titles
        Services::AlternateTitles::Writer.replace(record: record, titles: titles, source: :admin, user: current_user)
        record.save! if record.changed?
      end
      saved = true
    end
    saved
  end
end
