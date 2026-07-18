require "test_helper"

module Admin
  module Books
    class AuthorsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        @author = books_authors(:tolstoy)
        host! Rails.application.config.domains[:books]
      end

      test "search redirects a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get search_admin_books_authors_path(q: "tol")
        assert_redirected_to books_root_path
      end

      test "search returns autocomplete JSON for an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        ::Search::Books::Search::AuthorAutocomplete.expects(:call).with("tol", size: 20).returns([{id: @author.id.to_s, score: 1.0, source: {"name" => @author.name}}])
        get search_admin_books_authors_path(q: "tol")
        assert_response :success
        body = JSON.parse(response.body)
        assert_equal @author.id, body.first["value"]
        assert_equal @author.name, body.first["text"]
      end

      test "search returns an empty array when nothing matches" do
        sign_in_as(@admin_user, stub_auth: true)
        ::Search::Books::Search::AuthorAutocomplete.stubs(:call).returns([])
        get search_admin_books_authors_path(q: "zzz")
        assert_response :success
        assert_equal [], JSON.parse(response.body)
      end

      # Authorization

      test "index redirects to root for unauthenticated users" do
        get admin_books_authors_path
        assert_redirected_to books_root_path
      end

      test "index redirects to root for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_authors_path
        assert_redirected_to books_root_path
      end

      test "index allows an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_authors_path
        assert_response :success
      end

      test "index allows a books domain editor" do
        @regular_user.domain_roles.create!(domain: :books, permission_level: :editor)
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_authors_path
        assert_response :success
      end

      # Index behavior

      test "index without a query renders the sorted list" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_authors_path
        assert_response :success
      end

      test "index with a query loads authors from OpenSearch in relevance order" do
        sign_in_as(@admin_user, stub_auth: true)
        ::Search::Books::Search::AuthorGeneral.stubs(:call).returns([{id: @author.id.to_s, score: 1.0, source: {"name" => @author.name}}])
        get admin_books_authors_path(q: "tol")
        assert_response :success
      end

      test "index with a query that matches nothing does not error" do
        sign_in_as(@admin_user, stub_auth: true)
        ::Search::Books::Search::AuthorGeneral.stubs(:call).returns([])
        get admin_books_authors_path(q: "zzzznomatch")
        assert_response :success
      end

      test "index tolerates a malicious sort param without raising" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_nothing_raised do
          get admin_books_authors_path(sort: "'; DROP TABLE books_authors; --")
        end
        assert_response :success
      end

      # Typeahead exclude_id

      test "search omits the excluded author id" do
        sign_in_as(@admin_user, stub_auth: true)
        other = books_authors(:king)
        ::Search::Books::Search::AuthorAutocomplete.stubs(:call).returns([{id: @author.id.to_s, score: 1.0, source: {}}, {id: other.id.to_s, score: 0.9, source: {}}])
        get search_admin_books_authors_path(q: "e", exclude_id: @author.id)
        ids = JSON.parse(response.body).map { |r| r["value"] }
        assert_not_includes ids, @author.id
        assert_includes ids, other.id
      end

      # Show

      test "show renders for an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_author_path(@author)
        assert_response :success
      end

      test "show redirects a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_author_path(@author)
        assert_redirected_to books_root_path
      end

      # New / create

      test "new renders for a writer" do
        sign_in_as(@admin_user, stub_auth: true)
        get new_admin_books_author_path
        assert_response :success
      end

      test "create makes an author and redirects to it" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_difference("::Books::Author.count", 1) do
          post admin_books_authors_path, params: {books_author: {name: "A Brand New Author", kind: "person", birth_year: 1950}}
        end
        assert_redirected_to admin_books_author_path(::Books::Author.order(:created_at).last)
      end

      test "create sets the kind" do
        sign_in_as(@admin_user, stub_auth: true)
        post admin_books_authors_path, params: {books_author: {name: "A Collective", kind: "collective"}}
        assert_equal "collective", ::Books::Author.find_by(name: "A Collective").kind
      end

      test "create splits comma-separated alternate names into the array column" do
        sign_in_as(@admin_user, stub_auth: true)
        post admin_books_authors_path, params: {books_author: {name: "Alt Name Author", kind: "person", alternate_names_string: "First Alt,  Second Alt , "}}
        author = ::Books::Author.find_by(name: "Alt Name Author")
        assert_equal ["First Alt", "Second Alt"], author.alternate_names
      end

      test "create rejects an invalid author" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_no_difference("::Books::Author.count") do
          post admin_books_authors_path, params: {books_author: {name: "", kind: "person"}}
        end
        assert_response :unprocessable_entity
      end

      test "create is forbidden for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        assert_no_difference("::Books::Author.count") do
          post admin_books_authors_path, params: {books_author: {name: "Nope", kind: "person"}}
        end
        assert_redirected_to books_root_path
      end

      # Edit / update / destroy

      test "edit renders for a writer" do
        sign_in_as(@admin_user, stub_auth: true)
        get edit_admin_books_author_path(@author)
        assert_response :success
      end

      test "update changes the author and redirects" do
        sign_in_as(@admin_user, stub_auth: true)
        patch admin_books_author_path(@author), params: {books_author: {name: "Lev Tolstoy (Revised)"}}
        assert_redirected_to admin_books_author_path(@author)
        assert_equal "Lev Tolstoy (Revised)", @author.reload.name
      end

      test "update leaves alternate_names untouched when the field is absent" do
        @author.update!(alternate_names: ["Lev Tolstoy"])
        sign_in_as(@admin_user, stub_auth: true)
        patch admin_books_author_path(@author), params: {books_author: {name: @author.name}}
        assert_equal ["Lev Tolstoy"], @author.reload.alternate_names
      end

      test "update clears alternate_names when the field is submitted empty" do
        @author.update!(alternate_names: ["Lev Tolstoy"])
        sign_in_as(@admin_user, stub_auth: true)
        patch admin_books_author_path(@author), params: {books_author: {name: @author.name, alternate_names_string: ""}}
        assert_equal [], @author.reload.alternate_names
      end

      test "update rejects invalid data" do
        sign_in_as(@admin_user, stub_auth: true)
        patch admin_books_author_path(@author), params: {books_author: {name: ""}}
        assert_response :unprocessable_entity
        assert @author.reload.name.present?
      end

      test "destroy deletes the author" do
        author = ::Books::Author.create!(name: "Disposable Author", kind: "person")
        sign_in_as(@admin_user, stub_auth: true)
        assert_difference("::Books::Author.count", -1) do
          delete admin_books_author_path(author)
        end
        assert_redirected_to admin_books_authors_path
      end

      test "destroy is forbidden for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        assert_no_difference("::Books::Author.count") do
          delete admin_books_author_path(@author)
        end
        assert_redirected_to books_root_path
      end

      # Images

      test "the author images index frame renders for the author" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_author_images_path(@author)
        assert_response :success
      end

      test "uploading an image attaches it to the author via the shared images controller" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_difference("Image.count", 1) do
          post admin_books_author_images_path(@author), params: {
            image: {
              file: fixture_file_upload("test_image.png", "image/png"),
              notes: "Portrait",
              primary: true
            }
          }
        end
        assert_includes @author.reload.images.map(&:id), Image.order(:created_at).last.id
      end

      # Inbound relationships card

      test "show renders for an author that has inbound relationships" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_author_path(books_authors(:king))
        assert_response :success
      end
    end
  end
end
