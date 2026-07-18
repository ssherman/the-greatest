require "test_helper"

module Admin
  module Books
    class AuthorRelationshipsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        @author = books_authors(:tolstoy)
        host! Rails.application.config.domains[:books]
      end

      test "create adds a relationship and redirects" do
        sign_in_as(@admin_user, stub_auth: true)
        other = books_authors(:king)
        assert_difference("@author.author_relationships.count", 1) do
          post admin_books_author_author_relationships_path(@author), params: {books_author_relationship: {to_author_id: other.id, relation_type: "member_of"}}
        end
        assert_redirected_to admin_books_author_path(@author)
        assert_equal "member_of", @author.author_relationships.order(:created_at).last.relation_type
      end

      test "create rejects a self-reference" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_no_difference("::Books::AuthorRelationship.count") do
          post admin_books_author_author_relationships_path(@author), params: {books_author_relationship: {to_author_id: @author.id, relation_type: "pseudonym_of"}}
        end
        assert_redirected_to admin_books_author_path(@author)
      end

      test "create is forbidden for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        other = books_authors(:king)
        assert_no_difference("::Books::AuthorRelationship.count") do
          post admin_books_author_author_relationships_path(@author), params: {books_author_relationship: {to_author_id: other.id, relation_type: "member_of"}}
        end
        assert_redirected_to books_root_path
      end

      test "update changes the relation type" do
        sign_in_as(@admin_user, stub_auth: true)
        other = books_authors(:king)
        rel = @author.author_relationships.create!(to_author: other, relation_type: :pseudonym_of)
        patch admin_books_author_relationship_path(rel), params: {books_author_relationship: {relation_type: "member_of"}}
        assert_redirected_to admin_books_author_path(@author)
        assert_equal "member_of", rel.reload.relation_type
      end

      test "destroy removes the relationship" do
        sign_in_as(@admin_user, stub_auth: true)
        other = books_authors(:king)
        rel = @author.author_relationships.create!(to_author: other, relation_type: :pseudonym_of)
        assert_difference("::Books::AuthorRelationship.count", -1) do
          delete admin_books_author_relationship_path(rel)
        end
        assert_redirected_to admin_books_author_path(@author)
      end
    end
  end
end
