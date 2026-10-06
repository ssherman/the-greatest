require "test_helper"

class Books::My::GoodreadsImportsControllerTest < ActionDispatch::IntegrationTest
  include GoodreadsImportHelper

  setup do
    host! Rails.application.config.domains[:books]
    @user = User.create!(email: "member-import@example.com", role: :user, email_verified: false)
    @import = @user.goodreads_imports.create!(status: :complete, rows_count: 1)
    @import.rows.create!(row_number: 1, raw: {"Title" => "War and Peace", "Author" => "Leo Tolstoy"}, outcome: :failed, error: "x")
  end

  def upload
    bytes = goodreads_csv({"Book Id" => "656", "Title" => "War and Peace", "Author" => "Leo Tolstoy", "Exclusive Shelf" => "read"})
    Rack::Test::UploadedFile.new(StringIO.new(bytes), "text/csv", original_filename: "export.csv")
  end

  test "every action needs a signed-in user" do
    get books_my_goodreads_imports_path
    assert_response :redirect
    post books_my_goodreads_imports_path, params: {goodreads_import: {file: upload}}
    assert_response :redirect
    get books_my_goodreads_import_path(@import)
    assert_response :redirect
  end

  test "index lists only the member's own member imports and is not cached" do
    other = users(:regular_user).goodreads_imports.create!(status: :complete)
    @user.goodreads_imports.create!(status: :complete, source: :legacy_replay, legacy_import_id: 8101)
    sign_in_as(@user, stub_auth: true)

    get books_my_goodreads_imports_path

    assert_response :success
    assert_includes response.headers.fetch("Cache-Control"), "no-store"
    assert_equal [@import.id], @controller.view_assigns.fetch("imports").map(&:id)
    assert_not_includes @controller.view_assigns.fetch("imports").map(&:id), other.id
  end

  test "create starts an import and redirects to its summary" do
    ::Books::Goodreads::RunImportJob.stubs(:perform_async)
    sign_in_as(@user, stub_auth: true)

    assert_difference -> { @user.goodreads_imports.count }, 1 do
      post books_my_goodreads_imports_path, params: {goodreads_import: {file: upload}}
    end

    assert_redirected_to books_my_goodreads_import_path(@user.goodreads_imports.order(:id).last)
  end

  test "a refused upload re-renders the page as unprocessable" do
    sign_in_as(@user, stub_auth: true)

    assert_no_difference -> { ::Books::GoodreadsImport.count } do
      post books_my_goodreads_imports_path, params: {goodreads_import: {file: nil}}
    end

    assert_response :unprocessable_entity
    assert_not_empty @controller.view_assigns.fetch("errors")
  end

  test "show is the member's own import; another member's is a 404" do
    sign_in_as(@user, stub_auth: true)
    get books_my_goodreads_import_path(@import)
    assert_response :success

    other = users(:regular_user).goodreads_imports.create!(status: :complete)
    get books_my_goodreads_import_path(other)
    assert_response :not_found
  end

  test "show renders a written row with links to its book and the corrections form" do
    book = books_books(:war_and_peace)
    edition = goodreads_edition(title: "Member Show Book", book: book, resolution: :matched, resolved_at: Time.current)
    @import.rows.create!(row_number: 2, goodreads_edition: edition, outcome: :applied, raw: {"Title" => "War and Peace"})
    sign_in_as(@user, stub_auth: true)

    get books_my_goodreads_import_path(@import)

    assert_response :success
    assert_select "a[href=?]", books_book_correction_path(slug: book.slug)
  end

  test "show asks the browser to refresh only while the import runs" do
    sign_in_as(@user, stub_auth: true)
    get books_my_goodreads_import_path(@import)
    assert_nil response.headers["Refresh"]

    @import.update!(status: :resolving)
    get books_my_goodreads_import_path(@import)
    assert_equal "10", response.headers["Refresh"]
  end
end
