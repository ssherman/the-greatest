require "test_helper"

# == Schema Information
#
# Table name: categories
#
#  id                :bigint           not null, primary key
#  alternative_names :string           default([]), is an Array
#  category_type     :integer          default("genre")
#  deleted           :boolean          default(FALSE)
#  description       :text
#  import_source     :integer
#  item_count        :integer          default(0)
#  name              :string           not null
#  slug              :string
#  type              :string           not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  parent_id         :bigint
#
# Indexes
#
#  index_categories_on_category_type  (category_type)
#  index_categories_on_deleted        (deleted)
#  index_categories_on_name           (name)
#  index_categories_on_parent_id      (parent_id)
#  index_categories_on_slug           (slug)
#  index_categories_on_type           (type)
#  index_categories_on_type_and_slug  (type,slug)
#
# Foreign Keys
#
#  fk_rails_...  (parent_id => categories.id)
#
module Books
  class CategoryTest < ActiveSupport::TestCase
    test "location categories associate books" do
      russia = Books::Category.create!(name: "Russia", category_type: :location)
      CategoryItem.create!(category: russia, item: books_books(:war_and_peace))
      assert_includes russia.books, books_books(:war_and_peace)
    end

    test "location categories associate authors as nationality" do
      russia = Books::Category.create!(name: "Russia", category_type: :location)
      CategoryItem.create!(category: russia, item: books_authors(:tolstoy))
      assert_includes russia.authors, books_authors(:tolstoy)
    end

    test "by_book_ids scope filters" do
      fiction = Books::Category.create!(name: "Fiction", category_type: :genre)
      CategoryItem.create!(category: fiction, item: books_books(:war_and_peace))
      assert_includes Books::Category.by_book_ids([books_books(:war_and_peace).id]), fiction
    end

    test "by_author_ids scope filters" do
      russia = Books::Category.create!(name: "Russia", category_type: :location)
      CategoryItem.create!(category: russia, item: books_authors(:tolstoy))
      assert_includes Books::Category.by_author_ids([books_authors(:tolstoy).id]), russia
    end
  end
end
