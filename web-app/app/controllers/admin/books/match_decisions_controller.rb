class Admin::Books::MatchDecisionsController < Admin::MatchDecisionsBaseController
  private

  def domain = :books

  def route_prefix = "admin_books_"
end
