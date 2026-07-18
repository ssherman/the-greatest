class Admin::Books::AuthorsController < Admin::Books::BaseController
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
end
