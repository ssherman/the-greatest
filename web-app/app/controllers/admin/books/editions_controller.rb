class Admin::Books::EditionsController < Admin::Books::BaseController
  before_action :set_book, only: [:index]

  def index
    authorize ::Books::Edition
    @editions = @book.editions.includes(:language).order(popularity: :desc, id: :asc)
    render layout: false
  end

  private

  def set_book
    @book = ::Books::Book.find(params[:book_id])
  end
end
