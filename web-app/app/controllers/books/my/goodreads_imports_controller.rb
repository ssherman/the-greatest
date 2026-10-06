# The member's Goodreads import pages (Goodreads import spec §11): how to
# export, the upload form and past imports, and a summary per import that
# refreshes itself while the import runs.
class Books::My::GoodreadsImportsController < ApplicationController
  include Cacheable
  include Pagy::Method

  REFRESH_SECONDS = 10
  ROWS_PER_PAGE = 100

  layout "books/application"

  before_action :prevent_caching
  before_action :require_signed_in!

  def index
    @imports = imports
  end

  def create
    result = Services::Books::GoodreadsImports::StartImport.call(user: current_user, upload: params.dig(:goodreads_import, :file))
    if result.success?
      redirect_to books_my_goodreads_import_path(result.data[:import]), status: :see_other
    else
      @errors = result.errors
      @imports = imports
      render :index, status: :unprocessable_entity
    end
  end

  def show
    @import = imports.find(params[:id])
    response.headers["Refresh"] = REFRESH_SECONDS.to_s if @import.in_progress?
    @pagy, @rows = pagy(@import.rows.order(:row_number).includes(goodreads_edition: [:match_decision, :book]),
      limit: ROWS_PER_PAGE)
  end

  private

  def imports
    current_user.goodreads_imports.member.order(created_at: :desc)
  end
end
