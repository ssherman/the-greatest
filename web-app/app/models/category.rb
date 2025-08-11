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
class Category < ApplicationRecord
  extend FriendlyId

  # FriendlyId configuration with scoping by STI type
  friendly_id :name, use: [:slugged, :scoped], scope: :type

  # Rails 8 enum syntax
  enum :category_type, {genre: 0, location: 1, subject: 2}
  enum :import_source, {amazon: 0, open_library: 1, openai: 2, goodreads: 3, musicbrainz: 4}

  # Associations
  belongs_to :parent, class_name: "Category", optional: true
  has_many :child_categories, class_name: "Category", foreign_key: :parent_id, dependent: :nullify
  has_many :category_items, dependent: :destroy
  has_many :ai_chats, as: :parent, dependent: :destroy

  # Validations
  validates :name, presence: true
  validates :type, presence: true

  # Scopes
  scope :active, -> { where(deleted: false) }
  scope :soft_deleted, -> { where(deleted: true) }
  scope :sorted_by_name, -> { order(:name) }
  scope :sorted_by_item_count, -> { order(item_count: :desc) }
  scope :search, ->(query) { where("name ILIKE ?", "%#{query}%") }
  scope :search_by_name, ->(name) { where("name ILIKE ?", "%" + sanitize_sql_like(name) + "%") }
  scope :by_name, ->(name) { where("LOWER(name) = LOWER(?)", name) }

  # Search by alternative names using PostgreSQL array operations
  scope :by_alternative_name, ->(name) {
    where("EXISTS (
      SELECT 1
      FROM unnest(alternative_names) AS unnested
      WHERE lower(unnested) = ?
    )", name.downcase)
  }

  # Override to_param for FriendlyId
  def to_param
    slug
  end

  # Check if category should regenerate friendly_id when name changes
  def should_generate_new_friendly_id?
    slug.blank? || name_changed?
  end
end
