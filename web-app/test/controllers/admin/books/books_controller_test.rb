require "test_helper"

module Admin
  module Books
    class BooksControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @editor_user = users(:editor_user)
        @regular_user = users(:regular_user)
        @book = books_books(:war_and_peace)

        host! Rails.application.config.domains[:books]
      end

      # Authorization

      test "index redirects to root for unauthenticated users" do
        get admin_books_books_path
        assert_redirected_to books_root_path
      end

      test "index redirects to root for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_books_path
        assert_redirected_to books_root_path
      end

      test "index allows an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_books_path
        assert_response :success
      end

      test "index allows a books domain editor" do
        @regular_user.domain_roles.create!(domain: :books, permission_level: :editor)
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_books_path
        assert_response :success
      end

      # Index behavior

      test "index without a query renders the sorted list" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_books_path
        assert_response :success
      end

      test "index with a query loads books from OpenSearch in relevance order" do
        sign_in_as(@admin_user, stub_auth: true)
        ::Search::Books::Search::BookGeneral.stubs(:call).returns([{id: @book.id.to_s, score: 1.0, source: {"title" => @book.title}}])
        get admin_books_books_path(q: "war")
        assert_response :success
      end

      test "index with a query that matches nothing does not error" do
        sign_in_as(@admin_user, stub_auth: true)
        ::Search::Books::Search::BookGeneral.stubs(:call).returns([])
        get admin_books_books_path(q: "zzzznomatch")
        assert_response :success
      end

      test "index tolerates a malicious sort param without raising" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_nothing_raised do
          get admin_books_books_path(sort: "'; DROP TABLE books_books; --")
        end
        assert_response :success
      end

      # Typeahead

      test "search returns autocomplete JSON" do
        sign_in_as(@admin_user, stub_auth: true)
        ::Search::Books::Search::BookAutocomplete.expects(:call).with("war", size: 20).returns([{id: @book.id.to_s, score: 1.0, source: {"title" => @book.title}}])
        get search_admin_books_books_path(q: "war")
        assert_response :success
        body = JSON.parse(response.body)
        assert_equal @book.id, body.first["value"]
        assert_includes body.first["text"], @book.title
      end

      test "search returns an empty array when nothing matches" do
        sign_in_as(@admin_user, stub_auth: true)
        ::Search::Books::Search::BookAutocomplete.stubs(:call).returns([])
        get search_admin_books_books_path(q: "zzz")
        assert_response :success
        assert_equal [], JSON.parse(response.body)
      end

      # Show

      test "show renders for an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_book_path(@book)
        assert_response :success
      end

      test "show redirects a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_book_path(@book)
        assert_redirected_to books_root_path
      end

      # New / create

      test "new renders for a writer" do
        sign_in_as(@admin_user, stub_auth: true)
        get new_admin_books_book_path
        assert_response :success
      end

      test "create makes a book and redirects to it" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_difference("::Books::Book.count", 1) do
          post admin_books_books_path, params: {books_book: {title: "A Brand New Book", book_kind: "standalone", first_published_year: 1999}}
        end
        assert_redirected_to admin_books_book_path(::Books::Book.order(:created_at).last)
      end

      test "create splits comma-separated alternate titles into the array column" do
        sign_in_as(@admin_user, stub_auth: true)
        post admin_books_books_path, params: {books_book: {title: "Alt Title Book", book_kind: "standalone", alternate_titles_string: "First Alt,  Second Alt , "}}
        book = ::Books::Book.find_by(title: "Alt Title Book")
        assert_equal ["First Alt", "Second Alt"], book.alternate_titles
      end

      test "create rejects an invalid book" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_no_difference("::Books::Book.count") do
          post admin_books_books_path, params: {books_book: {title: "", book_kind: "standalone"}}
        end
        assert_response :unprocessable_entity
      end

      test "create is forbidden for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        assert_no_difference("::Books::Book.count") do
          post admin_books_books_path, params: {books_book: {title: "Nope", book_kind: "standalone"}}
        end
        assert_redirected_to books_root_path
      end

      # Edit / update / destroy

      test "edit renders for a writer" do
        sign_in_as(@admin_user, stub_auth: true)
        get edit_admin_books_book_path(@book)
        assert_response :success
      end

      test "update changes the book and redirects" do
        sign_in_as(@admin_user, stub_auth: true)
        patch admin_books_book_path(@book), params: {books_book: {title: "War and Peace (Revised)"}}
        assert_redirected_to admin_books_book_path(@book)
        assert_equal "War and Peace (Revised)", @book.reload.title
      end

      test "update leaves alternate_titles untouched when the field is absent" do
        @book.update!(alternate_titles: ["Voyna i mir"])
        sign_in_as(@admin_user, stub_auth: true)
        patch admin_books_book_path(@book), params: {books_book: {title: @book.title}}
        assert_equal ["Voyna i mir"], @book.reload.alternate_titles
      end

      test "update clears alternate_titles when the field is submitted empty" do
        @book.update!(alternate_titles: ["Voyna i mir"])
        sign_in_as(@admin_user, stub_auth: true)
        patch admin_books_book_path(@book), params: {books_book: {title: @book.title, alternate_titles_string: ""}}
        assert_equal [], @book.reload.alternate_titles
      end

      test "update rejects invalid data" do
        sign_in_as(@admin_user, stub_auth: true)
        patch admin_books_book_path(@book), params: {books_book: {title: ""}}
        assert_response :unprocessable_entity
        assert @book.reload.title.present?
      end

      test "destroy deletes the book" do
        book = ::Books::Book.create!(title: "Disposable", book_kind: "standalone")
        sign_in_as(@admin_user, stub_auth: true)
        assert_difference("::Books::Book.count", -1) do
          delete admin_books_book_path(book)
        end
        assert_redirected_to admin_books_books_path
      end

      test "destroy is forbidden for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        assert_no_difference("::Books::Book.count") do
          delete admin_books_book_path(@book)
        end
        assert_redirected_to books_root_path
      end

      # Images

      test "the book images index frame renders for the book" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_book_images_path(@book)
        assert_response :success
      end

      test "uploading an image attaches it to the book via the shared images controller" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_difference("Image.count", 1) do
          post admin_books_book_images_path(@book), params: {
            image: {
              file: fixture_file_upload("test_image.png", "image/png"),
              notes: "Cover",
              primary: true
            }
          }
        end
        assert_includes @book.reload.images.map(&:id), Image.order(:created_at).last.id
      end
    end
  end
end
