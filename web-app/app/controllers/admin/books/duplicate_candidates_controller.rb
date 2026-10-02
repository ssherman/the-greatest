class Admin::Books::DuplicateCandidatesController < Admin::DuplicateCandidatesBaseController
  private

  def domain = :books

  def route_prefix = "admin_books_"
end
