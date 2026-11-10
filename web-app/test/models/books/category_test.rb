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
#  merged_into_id    :bigint
#  parent_id         :bigint
#
# Indexes
#
#  index_categories_on_category_type   (category_type)
#  index_categories_on_deleted         (deleted)
#  index_categories_on_merged_into_id  (merged_into_id)
#  index_categories_on_name            (name)
#  index_categories_on_parent_id       (parent_id)
#  index_categories_on_slug            (slug)
#  index_categories_on_type            (type)
#  index_categories_on_type_and_slug   (type,slug)
#
# Foreign Keys
#
#  fk_rails_...  (merged_into_id => categories.id)
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

    def location(name, parent: nil)
      ::Books::Category.create!(name: name, category_type: :location, parent: parent)
    end

    test "ancestors walks up the parent chain, nearest first" do
      na = location("North America")
      us = location("United States", parent: na)
      il = location("Illinois", parent: us)
      chicago = location("Chicago", parent: il)

      assert_equal [il, us, na], chicago.ancestors
      assert_equal [], na.ancestors
    end

    test "a location's parent must be a books location" do
      subject = ::Books::Category.create!(name: "War", category_type: :subject)
      place = ::Books::Category.new(name: "Somewhere", category_type: :location, parent: subject)

      refute place.valid?
      assert_includes place.errors[:parent_id], "must be a books location"
    end

    test "a location can't be re-parented under its own descendant" do
      us = location("United States")
      il = location("Illinois", parent: us)
      us.parent = il

      refute us.valid?
      assert_includes us.errors[:parent_id], "would create a cycle"
    end

    test "genres keep their existing freedom to have any parent" do
      parent = ::Books::Category.create!(name: "Speculative", category_type: :genre)
      child = ::Books::Category.new(name: "Space Opera", category_type: :genre, parent: parent)
      assert child.valid?
    end

    test "protected_ids are the four book-type categories resolved through LegacyIdMap" do
      fiction = categories(:books_fiction_genre)
      LegacyIdMap.record(model: "Books::Category", legacy_id: ::Books::BookType::LEGACY_CATEGORY_IDS[0], new_id: fiction.id)
      ::Books::BookType.reset_category_ids!

      assert_includes ::Books::Category.protected_ids, fiction.id
    ensure
      ::Books::BookType.reset_category_ids!
    end

    test "a subject with a subject parent can't be retyped to location" do
      parent = ::Books::Category.create!(name: "History", category_type: :subject)
      child = ::Books::Category.create!(name: "Wars", category_type: :subject, parent: parent)

      refute child.update(category_type: :location)
      assert_includes child.errors[:parent_id], "must be a books location"
    end

    test "a location with active child places can't be retyped" do
      us = location("United States")
      location("Illinois", parent: us)

      refute us.update(category_type: :subject)
      assert_includes us.errors[:category_type], "can't change while places are listed under it"
    end

    test "a location with only a soft-deleted child can be retyped" do
      us = location("United States")
      child = location("Illinois", parent: us)
      child.update!(deleted: true)

      assert us.update(category_type: :subject)
    end

    test "retyping a leaf location clears its parent" do
      us = location("United States")
      il = location("Illinois", parent: us)

      assert il.update(category_type: :subject)
      assert_nil il.reload.parent_id
    end

    test "a failed retype leaves parent_id unchanged in memory" do
      us = location("United States")
      il = location("Illinois", parent: us)

      refute il.update(category_type: :subject, name: "")
      assert_equal us.id, il.parent_id

      parent_place = location("Parent Place")
      child_place = location("Child Place", parent: parent_place)
      location("Grandchild", parent: child_place)
      refute child_place.update(category_type: :subject)
      assert_equal parent_place.id, child_place.parent_id
    end

    test "retyping a location keeps a new non-location parent chosen in the same request" do
      us = location("United States")
      chicago = location("Chicago", parent: us)
      history = ::Books::Category.create!(name: "American History", category_type: :subject)

      assert chicago.update(category_type: :subject, parent_id: history.id)
      assert_equal history.id, chicago.reload.parent_id
    end

    test "a subject keeps its parent when its type is unchanged" do
      parent = ::Books::Category.create!(name: "History", category_type: :subject)
      child = ::Books::Category.create!(name: "Wars", category_type: :subject, parent: parent)

      assert child.update(name: "Wars and Battles")
      assert_equal parent.id, child.reload.parent_id
    end

    test "type_label calls a location a Setting and titleizes the rest" do
      assert_equal "Setting", categories(:books_france_location).type_label
      assert_equal "Subject", categories(:books_politics_subject).type_label
      assert_equal "Genre", categories(:books_fiction_genre).type_label
    end
  end
end
