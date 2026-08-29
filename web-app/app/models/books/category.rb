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
  class Category < ::Category
    has_many :books, through: :category_items, source: :item, source_type: "Books::Book"
    has_many :authors, through: :category_items, source: :item, source_type: "Books::Author"

    scope :by_book_ids, ->(book_ids) { joins(:category_items).where(category_items: {item_type: "Books::Book", item_id: book_ids}) }
    scope :by_author_ids, ->(author_ids) { joins(:category_items).where(category_items: {item_type: "Books::Author", item_id: author_ids}) }

    # Books reads more of the category row than any other domain.
    # Books::Book#as_indexed_json splits genre_category_ids / subject_category_ids /
    # location_category_ids by category_type, and similarity_category_count -- the
    # denominator the similarity query divides by -- excludes the Fiction and
    # Nonfiction genre rows by NAME.
    #
    # Name is compared as membership rather than as a string on purpose: it only ever
    # reaches the indexed document through BOOK_TYPE_CATEGORY_NAMES.include?, so
    # fixing a typo on a 30,000-item category requeues nothing, while renaming one
    # into or out of Fiction/Nonfiction requeues everything it holds.
    def search_relevant_change?
      super || saved_change_to_category_type? || book_type_membership_changed?
    end

    private

    def book_type_membership_changed?
      return false unless saved_change_to_name?

      before, after = saved_change_to_name
      ::Books::Book::BOOK_TYPE_CATEGORY_NAMES.include?(before) !=
        ::Books::Book::BOOK_TYPE_CATEGORY_NAMES.include?(after)
    end
  end
end
