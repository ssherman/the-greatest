require "test_helper"

# == Schema Information
#
# Table name: books_authors
#
#  id              :bigint           not null, primary key
#  alternate_names :string           default([]), not null, is an Array
#  birth_year      :integer
#  death_year      :integer
#  description     :text
#  kind            :integer          default("person"), not null
#  name            :string           not null
#  slug            :string           not null
#  sort_name       :string
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#
# Indexes
#
#  index_books_authors_on_alternate_names  (alternate_names) USING gin
#  index_books_authors_on_kind             (kind)
#  index_books_authors_on_slug             (slug) UNIQUE
#
module Books
  class AuthorTest < ActiveSupport::TestCase
    test "is valid with a name" do
      assert_predicate Books::Author.new(name: "Leo Tolstoy"), :valid?
    end

    test "requires a name" do
      author = Books::Author.new
      assert_not author.valid?
      assert_includes author.errors[:name], "can't be blank"
    end

    test "generates a slug from the name" do
      author = Books::Author.create!(name: "Fyodor Dostoevsky")
      assert_equal "fyodor-dostoevsky", author.slug
    end

    test "defaults to person kind" do
      assert_predicate Books::Author.new(name: "X"), :person?
    end

    test "supports pseudonym kind" do
      assert_predicate books_authors(:bachman), :pseudonym?
    end

    test "as_indexed_json includes name and alternate_names" do
      json = books_authors(:tolstoy).as_indexed_json
      assert_equal "Leo Tolstoy", json[:name]
      assert_kind_of Array, json[:alternate_names]
    end

    # SearchIndexable concern tests
    test "should create search index request on create" do
      assert_difference "SearchIndexRequest.count", 1 do
        Books::Author.create!(name: "Test Search Author")
      end

      request = SearchIndexRequest.last
      assert_equal "Books::Author", request.parent_type
      assert request.index_item?
    end

    test "should create search index request on destroy" do
      author = books_authors(:garnett)

      assert_difference "SearchIndexRequest.count", 1 do
        author.destroy!
      end

      request = SearchIndexRequest.last
      assert_equal author.id, request.parent_id
      assert_equal "Books::Author", request.parent_type
      assert request.unindex_item?
    end
  end
end
