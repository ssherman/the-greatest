require "test_helper"

module Admin
  module Books
    class AlternateTitlesControllerTest < ActionDispatch::IntegrationTest
      setup do
        host! Rails.application.config.domains[:books]
        @admin = users(:admin_user)
        @viewer = users(:books_viewer_user)
        @book = books_books(:war_and_peace)
        @other = books_books(:crime_and_punishment)
        @kept = alternate_titles(:war_and_peace_voyna)
        @removed = alternate_titles(:crime_and_punishment_removed_junk)
        @review = make_row(@book, "War and Peace, Part One", :review, source: :ai_enrichment)
        @admin_review = make_row(@other, "Prestuplenie", :review, source: :admin)
      end

      def make_row(record, title, status, source: :legacy)
        AlternateTitle.create!(titleable: record, title: title, status: status, source: source)
      end

      def row_ids
        css_select("[data-testid=alternate-title-row]").map { |row| row["data-alternate-title-id"].to_i }
      end

      test "index renders the book rows" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_book_alternate_titles_path(@book)
        assert_response :success
        assert_select "turbo-frame#alternate_titles_list"
        assert_equal [@kept.id, @review.id], row_ids
      end

      test "index has no frame trapped links" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_book_alternate_titles_path(@book)
        assert_no_frame_trapped_links(admin_books_book_alternate_titles_path(@book))
      end

      test "review lists only review rows" do
        sign_in_as(@admin, stub_auth: true)
        get review_admin_books_alternate_titles_path
        assert_response :success
        assert_equal [@review.id, @admin_review.id], row_ids
      end

      test "review filters by source" do
        sign_in_as(@admin, stub_auth: true)
        get review_admin_books_alternate_titles_path(source: "admin")
        assert_equal [@admin_review.id], row_ids
        get review_admin_books_alternate_titles_path(source: "bogus")
        assert_response :success
        assert_equal [@review.id, @admin_review.id], row_ids
      end

      test "keep marks a review row kept" do
        sign_in_as(@admin, stub_auth: true)
        post keep_admin_books_alternate_title_path(@review)
        assert_redirected_to admin_books_book_path(@book)
        @review.reload
        assert_predicate @review, :kept?
        assert_predicate @review, :decided_by_admin?
        assert_equal @admin.id, @review.decided_by_user_id
      end

      test "remove marks it removed and updates the book array" do
        sign_in_as(@admin, stub_auth: true)
        post remove_admin_books_alternate_title_path(@kept)
        assert_redirected_to admin_books_book_path(@book)
        assert_predicate @kept.reload, :removed?
        assert_not_includes @book.reload.alternate_titles, "Voyna i mir"
      end

      test "remove also works on a review row" do
        sign_in_as(@admin, stub_auth: true)
        post remove_admin_books_alternate_title_path(@review)
        assert_predicate @review.reload, :removed?
      end

      test "restore brings back a removed row" do
        sign_in_as(@admin, stub_auth: true)
        post restore_admin_books_alternate_title_path(@removed)
        assert_redirected_to admin_books_book_path(@other)
        assert_predicate @removed.reload, :kept?
        assert_includes @other.reload.alternate_titles, @removed.title
      end

      test "restore on a kept row changes nothing" do
        sign_in_as(@admin, stub_auth: true)
        assert_no_changes -> { @kept.reload.attributes } do
          post restore_admin_books_alternate_title_path(@kept)
        end
        assert_redirected_to admin_books_book_path(@book)
        assert_not_nil flash[:alert]
      end

      test "keep on a kept row and remove on a removed row change nothing" do
        sign_in_as(@admin, stub_auth: true)
        assert_no_changes -> { [@kept.reload.attributes, @removed.reload.attributes] } do
          post keep_admin_books_alternate_title_path(@kept)
          post remove_admin_books_alternate_title_path(@removed)
        end
      end

      test "rows of other record types are not reachable" do
        row = make_row(::Music::Album.first, "Other", :review)
        sign_in_as(@admin, stub_auth: true)
        post keep_admin_books_alternate_title_path(row)
        assert_response :not_found
        assert_predicate row.reload, :review?
      end

      test "members require write access" do
        sign_in_as(@viewer, stub_auth: true)
        post keep_admin_books_alternate_title_path(@review)
        assert_redirected_to books_root_path
        post remove_admin_books_alternate_title_path(@kept)
        assert_redirected_to books_root_path
        post restore_admin_books_alternate_title_path(@removed)
        assert_redirected_to books_root_path
        assert_equal %w[review kept removed], [@review, @kept, @removed].map { |r| r.reload.status }
      end
    end
  end
end
