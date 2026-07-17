class Admin::Books::AuthorsController < Admin::Books::BaseController
  def search
    results = ::Search::Books::Search::AuthorAutocomplete.call(params[:q], size: 20)
    author_ids = results.map { |r| r[:id].to_i }

    if author_ids.empty?
      render json: []
      return
    end

    authors = ::Books::Author.where(id: author_ids).in_order_of(:id, author_ids)
    render json: authors.map { |a| {value: a.id, text: a.name} }
  end
end
