class Admin::Books::CategoriesController < Admin::CategoriesBaseController
  include Admin::DomainScopedAuth

  protected

  def model_class = ::Books::Category

  def param_key = :books_category

  def category_path(category) = admin_books_category_path(category)

  def categories_path = admin_books_categories_path

  def new_category_path = new_admin_books_category_path

  def edit_category_path(category) = edit_admin_books_category_path(category)

  def domain_label = "Books"

  def subtitle = "Manage book genres, subjects, locations, and themes"

  def load_show_stats
    @stats = {
      "Books" => @category.books.count,
      "Authors" => @category.authors.count
    }
  end
end
