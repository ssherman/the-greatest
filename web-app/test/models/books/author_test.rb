require "test_helper"

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
  end
end
