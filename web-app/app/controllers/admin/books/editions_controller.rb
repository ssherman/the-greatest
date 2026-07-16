class Admin::Books::EditionsController < Admin::Books::BaseController
  before_action :set_book, only: [:index]
  before_action :set_edition, only: [:show]
  before_action :authorize_edition, only: [:show]

  def index
    authorize ::Books::Edition
    @editions = @book.editions.includes(:language).order(popularity: :desc, id: :asc)
    render layout: false
  end

  def show
  end

  private

  def set_book
    @book = ::Books::Book.find(params[:book_id])
  end

  def set_edition
    @edition = ::Books::Edition.find(params[:id])
  end

  def authorize_edition
    authorize @edition
  end
end
