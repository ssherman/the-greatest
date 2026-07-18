require "test_helper"

module Admin
  module Books
    class SeriesControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        @series = books_series(:asoiaf)
        host! Rails.application.config.domains[:books]
      end

      # Authorization

      test "index redirects to root for unauthenticated users" do
        get admin_books_series_index_path
        assert_redirected_to books_root_path
      end

      test "index redirects to root for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_series_index_path
        assert_redirected_to books_root_path
      end

      test "index allows an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_series_index_path
        assert_response :success
      end

      test "index allows a books domain editor" do
        @regular_user.domain_roles.create!(domain: :books, permission_level: :editor)
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_series_index_path
        assert_response :success
      end

      # Index behavior (SQL ILIKE — no OpenSearch, no stubbing; mirrors games series tests)

      test "index without a query renders the sorted list" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_series_index_path
        assert_response :success
      end

      test "index with a matching query renders successfully" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_series_index_path(q: "song of ice")
        assert_response :success
      end

      test "index with a non-matching query renders successfully" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_series_index_path(q: "zzzznomatch")
        assert_response :success
      end

      test "index tolerates a malicious query without raising" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_nothing_raised do
          get admin_books_series_index_path(q: "100%_off'; DROP TABLE books_series; --")
        end
        assert_response :success
      end

      test "index tolerates a malicious sort param without raising" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_nothing_raised do
          get admin_books_series_index_path(sort: "'; DROP TABLE books_series; --")
        end
        assert_response :success
      end

      # Show

      test "show renders for an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_series_path(@series)
        assert_response :success
      end

      test "show redirects a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_series_path(@series)
        assert_redirected_to books_root_path
      end

      # New / create

      test "new renders for a writer" do
        sign_in_as(@admin_user, stub_auth: true)
        get new_admin_books_series_path
        assert_response :success
      end

      test "create makes a series and redirects to it" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_difference("::Books::Series.count", 1) do
          post admin_books_series_index_path, params: {books_series: {title: "A Brand New Series", description: "desc"}}
        end
        assert_redirected_to admin_books_series_path(::Books::Series.order(:created_at).last)
      end

      test "create rejects an invalid series" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_no_difference("::Books::Series.count") do
          post admin_books_series_index_path, params: {books_series: {title: ""}}
        end
        assert_response :unprocessable_entity
      end

      test "create is forbidden for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        assert_no_difference("::Books::Series.count") do
          post admin_books_series_index_path, params: {books_series: {title: "Nope"}}
        end
        assert_redirected_to books_root_path
      end

      # Edit / update / destroy

      test "edit renders for a writer" do
        sign_in_as(@admin_user, stub_auth: true)
        get edit_admin_books_series_path(@series)
        assert_response :success
      end

      test "update changes the series and redirects" do
        sign_in_as(@admin_user, stub_auth: true)
        patch admin_books_series_path(@series), params: {books_series: {title: "ASOIAF (Revised)"}}
        assert_redirected_to admin_books_series_path(@series)
        assert_equal "ASOIAF (Revised)", @series.reload.title
      end

      test "update rejects invalid data" do
        sign_in_as(@admin_user, stub_auth: true)
        patch admin_books_series_path(@series), params: {books_series: {title: ""}}
        assert_response :unprocessable_entity
        assert @series.reload.title.present?
      end

      test "destroy deletes the series" do
        series = ::Books::Series.create!(title: "Disposable Series")
        sign_in_as(@admin_user, stub_auth: true)
        assert_difference("::Books::Series.count", -1) do
          delete admin_books_series_path(series)
        end
        assert_redirected_to admin_books_series_index_path
      end

      test "destroy is forbidden for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        assert_no_difference("::Books::Series.count") do
          delete admin_books_series_path(@series)
        end
        assert_redirected_to books_root_path
      end

      # Images

      test "the series images index frame renders for the series" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_series_images_path(@series)
        assert_response :success
      end

      test "uploading an image attaches it to the series via the shared images controller" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_difference("Image.count", 1) do
          post admin_books_series_images_path(@series), params: {
            image: {
              file: fixture_file_upload("test_image.png", "image/png"),
              notes: "Cover",
              primary: true
            }
          }
        end
        assert_includes @series.reload.images.map(&:id), Image.order(:created_at).last.id
      end
    end
  end
end
