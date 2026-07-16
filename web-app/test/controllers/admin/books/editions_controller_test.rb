require "test_helper"

module Admin
  module Books
    class EditionsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        @book = books_books(:war_and_peace)
        @edition = books_editions(:wp_maude)

        host! Rails.application.config.domains[:books]
      end

      # Index (nested, lazy frame)

      test "index redirects to root for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_book_editions_path(@book)
        assert_redirected_to books_root_path
      end

      test "index renders the book's editions frame for an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_book_editions_path(@book)
        assert_response :success
      end

      test "index allows a books domain editor" do
        @regular_user.domain_roles.create!(domain: :books, permission_level: :editor)
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_book_editions_path(@book)
        assert_response :success
      end

      # Show

      test "show renders for an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_edition_path(@edition)
        assert_response :success
      end

      test "show redirects a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_edition_path(@edition)
        assert_redirected_to books_root_path
      end

      # Images (shared controller, resolved via edition_id)

      test "the edition images index frame renders" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_edition_images_path(@edition)
        assert_response :success
      end

      test "uploading an image attaches it to the edition" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_difference("Image.count", 1) do
          post admin_books_edition_images_path(@edition), params: {
            image: {
              file: fixture_file_upload("test_image.png", "image/png"),
              notes: "Edition cover",
              primary: true
            }
          }
        end
        assert_includes @edition.reload.images.map(&:id), Image.order(:created_at).last.id
      end

      # New / create

      test "new renders for a writer" do
        sign_in_as(@admin_user, stub_auth: true)
        get new_admin_books_book_edition_path(@book)
        assert_response :success
      end

      test "create makes an edition under the book and redirects to it" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_difference("@book.editions.count", 1) do
          post admin_books_book_editions_path(@book), params: {books_edition: {edition_type: "annotated", publication_year: 2005, publisher_name: "Test House", book_binding: "paperback"}}
        end
        edition = @book.editions.order(:created_at).last
        assert_redirected_to admin_books_edition_path(edition)
        assert_equal "annotated", edition.edition_type
        assert_equal "Test House", edition.publisher_name
      end

      test "create rejects an edition with no edition_type" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_no_difference("::Books::Edition.count") do
          post admin_books_book_editions_path(@book), params: {books_edition: {edition_type: ""}}
        end
        assert_response :unprocessable_entity
      end

      test "create is forbidden for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        assert_no_difference("::Books::Edition.count") do
          post admin_books_book_editions_path(@book), params: {books_edition: {edition_type: "standard"}}
        end
        assert_redirected_to books_root_path
      end
    end
  end
end
