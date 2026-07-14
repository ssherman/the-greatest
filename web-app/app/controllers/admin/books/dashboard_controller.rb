class Admin::Books::DashboardController < Admin::Books::BaseController
  def index
    @book_count = ::Books::Book.count
    @author_count = ::Books::Author.count
    @edition_count = ::Books::Edition.count
    @series_count = ::Books::Series.count
    @category_count = ::Books::Category.count
    @list_count = ::Books::List.count
    @recent_books = ::Books::Book.order(created_at: :desc).limit(5)
  end
end
