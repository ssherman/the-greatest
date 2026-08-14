class Admin::Books::ReviewsController < Admin::ReviewsBaseController
  include Admin::DomainScopedAuth

  private

  def reviewable_class = ::Books::Book

  def reviewable_includes = [{book_authors: :author}]

  def reviews_path = admin_books_reviews_path
end
