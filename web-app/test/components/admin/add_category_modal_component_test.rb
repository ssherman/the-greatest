require "test_helper"

module Admin
  class AddCategoryModalComponentTest < ActiveSupport::TestCase
    test "a book targets the books category-tag and search endpoints, never music" do
      book = books_books(:war_and_peace)
      component = Admin::AddCategoryModalComponent.new(item: book)
      helpers = Rails.application.routes.url_helpers

      assert_equal helpers.admin_books_book_category_items_path(book), component.form_url
      assert_equal helpers.search_admin_books_categories_path, component.search_url
    end

    test "an author targets the books author category-tag endpoint" do
      author = books_authors(:tolstoy)
      component = Admin::AddCategoryModalComponent.new(item: author)
      helpers = Rails.application.routes.url_helpers

      assert_equal helpers.admin_books_author_category_items_path(author), component.form_url
      assert_equal helpers.search_admin_books_categories_path, component.search_url
    end
  end
end
