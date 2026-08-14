class Admin::Books::ReviewsController < Admin::ReviewsBaseController
  include Admin::DomainScopedAuth

  private

  def reviewable_class = ::Books::Book

  # The index view renders only reviewable.title -- no author column exists
  # today, so there is nothing here for book_authors/author to preload for.
  # Add it back if the view grows an author column.
  def reviewable_includes = []

  def reviews_index_path = admin_books_reviews_path
end
