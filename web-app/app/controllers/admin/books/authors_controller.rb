class Admin::Books::AuthorsController < Admin::Books::BaseController
  before_action :set_author, only: [:show, :edit, :update, :destroy]
  before_action :authorize_author, only: [:show, :edit, :update, :destroy]

  def index
    authorize ::Books::Author
    load_authors_for_index
  end

  def search
    results = ::Search::Books::Search::AuthorAutocomplete.call(params[:q], size: 20)
    author_ids = results.map { |r| r[:id].to_i }
    author_ids.delete(params[:exclude_id].to_i) if params[:exclude_id].present?

    if author_ids.empty?
      render json: []
      return
    end

    authors = ::Books::Author.where(id: author_ids).in_order_of(:id, author_ids)
    render json: authors.map { |a| {value: a.id, text: a.name} }
  end

  def show
  end

  def new
    @author = ::Books::Author.new
    authorize @author
  end

  def create
    @author = ::Books::Author.new
    assign_author_attributes(@author)
    authorize @author

    if @author.save
      redirect_to admin_books_author_path(@author), notice: "Author created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    assign_author_attributes(@author)

    if @author.save
      redirect_to admin_books_author_path(@author), notice: "Author updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @author.destroy!
    redirect_to admin_books_authors_path, notice: "Author deleted."
  end

  private

  def load_authors_for_index
    if params[:q].present?
      results = ::Search::Books::Search::AuthorGeneral.call(params[:q], size: 1000)
      author_ids = results.map { |r| r[:id].to_i }

      @authors = if author_ids.empty?
        ::Books::Author.none
      else
        ::Books::Author.where(id: author_ids).in_order_of(:id, author_ids)
      end
    else
      @authors = ::Books::Author.all.order(sortable_column(params[:sort]))
    end

    @pagy, @authors = pagy(@authors, limit: 25)
  end

  def sortable_column(column)
    {
      "id" => "books_authors.id",
      "name" => "books_authors.name",
      "sort_name" => "books_authors.sort_name",
      "kind" => "books_authors.kind",
      "birth_year" => "books_authors.birth_year",
      "death_year" => "books_authors.death_year",
      "created_at" => "books_authors.created_at"
    }.fetch(column, "books_authors.name")
  end

  def author_params
    params.require(:books_author).permit(:name, :sort_name, :kind, :birth_year, :death_year, :description)
  end

  def assign_author_attributes(record)
    record.assign_attributes(author_params)
    raw = params.dig(:books_author, :alternate_names_string)
    record.alternate_names = raw.to_s.split(",").map(&:strip).reject(&:blank?) unless raw.nil?
  end

  def set_author
    @author = ::Books::Author.find(params[:id])
  end

  def authorize_author
    authorize @author
  end
end
