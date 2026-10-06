class Admin::Books::GoodreadsImportsController < Admin::Books::BaseController
  def show
    @import = ::Books::GoodreadsImport.find(params[:id])
    head :ok
  end
end
