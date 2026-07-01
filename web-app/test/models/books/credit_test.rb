require "test_helper"

# == Schema Information
#
# Table name: books_credits
#
#  id              :bigint           not null, primary key
#  creditable_type :string           not null
#  position        :integer
#  role            :integer          default("translator"), not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  author_id       :bigint           not null
#  creditable_id   :bigint           not null
#
# Indexes
#
#  index_books_credits_on_author_id           (author_id)
#  index_books_credits_on_author_id_and_role  (author_id,role)
#  index_books_credits_on_creditable          (creditable_type,creditable_id)
#
# Foreign Keys
#
#  fk_rails_...  (author_id => books_authors.id)
#
module Books
  class CreditTest < ActiveSupport::TestCase
    test "is valid with author, creditable and role" do
      credit = Books::Credit.new(author: books_authors(:garnett), creditable: books_editions(:wp_maude), role: :translator)
      assert_predicate credit, :valid?
    end

    test "requires an author" do
      credit = Books::Credit.new(creditable: books_editions(:wp_maude), role: :translator)
      assert_not credit.valid?
      assert_includes credit.errors[:author], "must exist"
    end

    test "attaches to an edition as translator" do
      assert_equal :translator, books_credits(:wp_translator).role.to_sym
      assert_equal books_editions(:wp_maude), books_credits(:wp_translator).creditable
    end

    test "by_role scope filters" do
      assert_includes Books::Credit.by_role(:translator), books_credits(:wp_translator)
    end

    test "requires a creditable" do
      credit = Books::Credit.new(author: books_authors(:garnett), role: :translator)
      assert_not credit.valid?
      assert_includes credit.errors[:creditable], "must exist"
    end

    test "ordered scope sorts by position then id" do
      book = Books::Book.create!(title: "Credit Order Test Book")
      c2 = Books::Credit.create!(author: books_authors(:tolstoy), creditable: book, role: :foreword, position: 2)
      c1 = Books::Credit.create!(author: books_authors(:garnett), creditable: book, role: :translator, position: 1)
      ordered = Books::Credit.where(creditable: book).ordered
      assert_equal c1, ordered.first
      assert_equal c2, ordered.last
    end
  end
end
