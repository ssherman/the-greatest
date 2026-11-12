class Admin::Books::RankingArchivesController < Admin::Books::BaseController
  ENTRIES_ON_SHOW = 25

  before_action :set_archive, only: [:show, :edit, :update, :destroy]
  before_action :authorize_archive, only: [:show, :edit, :update, :destroy]

  def index
    authorize ::Books::RankingArchive
    # summaries leaves out the three big arrays; the list never needs them.
    @pagy, @archives = pagy(::Books::RankingArchive.summaries.newest_first, limit: 25)
  end

  def show
    @entries = ::Services::RankingArchives::Entries.call(archive: @archive, offset: 0, limit: ENTRIES_ON_SHOW)
  end

  def edit
  end

  def update
    if @archive.update(archive_params)
      redirect_to admin_books_ranking_archive_path(@archive), notice: "Archive updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @archive.destroy!
    redirect_to admin_books_ranking_archives_path, notice: "Archive deleted."
  end

  private

  def archive_params
    params.require(:books_ranking_archive).permit(:name, :slug, :description, :hidden)
  end

  def set_archive
    @archive = ::Books::RankingArchive.find(params[:id])
  end

  def authorize_archive
    authorize @archive
  end
end
