class Admin::Books::EditionsController < Admin::Books::BaseController
  before_action :set_book, only: [:index, :new, :create]
  before_action :set_edition, only: [:show, :edit, :update, :destroy, :set_default]
  before_action :authorize_edition, only: [:show, :edit, :update, :destroy, :set_default]

  def index
    authorize ::Books::Edition
    @editions = @book.editions.order(popularity: :desc, id: :asc)
    render layout: false
  end

  def show
  end

  def new
    @edition = @book.editions.build
    authorize @edition
  end

  def create
    @edition = @book.editions.build(edition_params)
    authorize @edition

    if @edition.save
      redirect_to admin_books_edition_path(@edition), notice: "Edition created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @edition.update(edition_params)
      redirect_to admin_books_edition_path(@edition), notice: "Edition updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    book = @edition.book
    @edition.destroy!
    redirect_to admin_books_book_path(book), notice: "Edition deleted."
  end

  def set_default
    @edition.book.update!(default_edition_id: @edition.id)
    redirect_to admin_books_book_path(@edition.book), notice: "Default edition updated."
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

  def edition_params
    params.require(:books_edition).permit(
      :title, :subtitle, :edition_type, :book_binding,
      :publication_year, :publisher_name, :page_count,
      :volume_number, :language_id, :popularity
    )
  end
end
