require "test_helper"

# == Schema Information
#
# Table name: categories
#
#  id                :bigint           not null, primary key
#  alternative_names :string           default([]), is an Array
#  category_type     :integer          default(0)
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
    def setup
      @novels = categories(:books_novels_genre)
      SearchIndexRequest.delete_all
    end

    test "changing category_type queues every book" do
      book_ids = CategoryItem.where(category_id: @novels.id, item_type: "Books::Book").pluck(:item_id)
      assert_equal 3, book_ids.size, "fixture drift: books_novels_genre should hold 3 books"

      @novels.update!(category_type: "subject")

      queued = SearchIndexRequest.where(parent_type: "Books::Book", action: :index_item).pluck(:parent_id)
      assert_equal book_ids.sort, queued.sort
    end

    test "renaming a category into Fiction queues its books" do
      assert_difference -> { SearchIndexRequest.count }, 3 do
        @novels.update!(name: "Fiction")
      end
    end

    test "renaming a category out of Nonfiction queues its books" do
      nonfiction = categories(:books_nonfiction_genre)
      CategoryItem.create!(category: nonfiction, item: books_books(:war_and_peace))
      SearchIndexRequest.delete_all

      assert_difference -> { SearchIndexRequest.count }, 1 do
        nonfiction.update!(name: "General Nonfiction")
      end
    end

    test "an unrelated rename queues nothing" do
      assert_no_difference -> { SearchIndexRequest.count } do
        @novels.update!(name: "Long Novels")
      end
    end

    test "editing description queues nothing" do
      assert_no_difference -> { SearchIndexRequest.count } do
        @novels.update!(description: "Fiction of novel length")
      end
    end

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
