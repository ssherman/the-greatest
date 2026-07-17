require "test_helper"

module Admin
  module Books
    class BookRelationshipsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        @book = books_books(:war_and_peace)
        host! Rails.application.config.domains[:books]
      end

      test "create adds a relationship and redirects" do
        sign_in_as(@admin_user, stub_auth: true)
        other = ::Books::Book.create!(title: "Related One", book_kind: "standalone")
        assert_difference("@book.book_relationships.count", 1) do
          post admin_books_book_book_relationships_path(@book), params: {books_book_relationship: {related_book_id: other.id, relation_type: "adaptation_of"}}
        end
        assert_redirected_to admin_books_book_path(@book)
        assert_equal "adaptation_of", @book.book_relationships.order(:created_at).last.relation_type
      end

      test "create rejects a self-reference" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_no_difference("::Books::BookRelationship.count") do
          post admin_books_book_book_relationships_path(@book), params: {books_book_relationship: {related_book_id: @book.id, relation_type: "related_to"}}
        end
        assert_redirected_to admin_books_book_path(@book)
      end

      test "create is forbidden for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        other = ::Books::Book.create!(title: "Related Two", book_kind: "standalone")
        assert_no_difference("::Books::BookRelationship.count") do
          post admin_books_book_book_relationships_path(@book), params: {books_book_relationship: {related_book_id: other.id, relation_type: "related_to"}}
        end
        assert_redirected_to books_root_path
      end

      test "update changes the relation type" do
        sign_in_as(@admin_user, stub_auth: true)
        other = ::Books::Book.create!(title: "Related Three", book_kind: "standalone")
        rel = @book.book_relationships.create!(related_book: other, relation_type: :contains)
        patch admin_books_book_relationship_path(rel), params: {books_book_relationship: {relation_type: "revision_of"}}
        assert_redirected_to admin_books_book_path(@book)
        assert_equal "revision_of", rel.reload.relation_type
      end

      test "destroy removes the relationship" do
        sign_in_as(@admin_user, stub_auth: true)
        other = ::Books::Book.create!(title: "Related Four", book_kind: "standalone")
        rel = @book.book_relationships.create!(related_book: other, relation_type: :contains)
        assert_difference("::Books::BookRelationship.count", -1) do
          delete admin_books_book_relationship_path(rel)
        end
        assert_redirected_to admin_books_book_path(@book)
      end
    end
  end
end
