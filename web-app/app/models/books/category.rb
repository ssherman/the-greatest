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
  class Category < ::Category
    has_many :books, through: :category_items, source: :item, source_type: "Books::Book"
    has_many :authors, through: :category_items, source: :item, source_type: "Books::Author"

    # Location trees are shallow; this caps any walk so a cycle written around
    # the validation (raw SQL) can't loop forever.
    MAX_DEPTH = 8

    validate :location_parent_is_valid, if: -> { location? && parent_id.present? && (will_save_change_to_parent_id? || will_save_change_to_category_type?) }

    validate :location_has_no_places_under_it, if: -> { will_save_change_to_category_type? && category_type_was == "location" && !location? }

    # A retyped leaf location can no longer have a location parent.
    before_validation :clear_parent_when_leaving_location, if: -> { persisted? && will_save_change_to_category_type? && category_type_was == "location" && !location? }

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

    # The four book-type categories (Fiction, Nonfiction, Religion & Spirituality,
    # Poetry). BookTypeCategoryMigrator raises if one is soft-deleted and saved
    # searches filter on them, so nothing may merge, delete or rename them.
    def self.protected_ids
      ::Books::BookType::LABELS.keys.filter_map { |value| ::Books::BookType.category_id(value) }
    end

    # Nearest first: Chicago -> [Illinois, United States, North America].
    def ancestors
      chain = []
      node = parent
      while node && chain.size < MAX_DEPTH
        chain << node
        node = node.parent
      end
      chain
    end

    private

    def location_parent_is_valid
      unless parent.is_a?(::Books::Category) && parent.location?
        errors.add(:parent_id, "must be a books location")
        return
      end
      errors.add(:parent_id, "would create a cycle") if parent == self || parent.ancestors.include?(self)
    end

    def location_has_no_places_under_it
      return unless child_categories.where(deleted: false).exists?

      errors.add(:category_type, "can't change while places are listed under it")
    end

    def clear_parent_when_leaving_location
      self.parent_id = nil
    end

    def book_type_membership_changed?
      return false unless saved_change_to_name?

      before, after = saved_change_to_name
      ::Books::Book::BOOK_TYPE_CATEGORY_NAMES.include?(before) !=
        ::Books::Book::BOOK_TYPE_CATEGORY_NAMES.include?(after)
    end
  end
end
