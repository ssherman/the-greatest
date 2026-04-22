# == Schema Information
#
# Table name: user_lists
#
#  id          :bigint           not null, primary key
#  description :text
#  list_type   :integer          not null
#  name        :string           not null
#  position    :integer
#  public      :boolean          default(FALSE), not null
#  type        :string           not null
#  view_mode   :integer          default("default_view"), not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  user_id     :bigint           not null
#
# Indexes
#
#  index_user_lists_on_public            (public) WHERE (public = true)
#  index_user_lists_on_user_id           (user_id)
#  index_user_lists_on_user_id_and_type  (user_id,type)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
class UserList < ApplicationRecord
  DEFAULT_SUBCLASSES = %w[
    Music::Albums::UserList
    Music::Songs::UserList
    Games::UserList
    Movies::UserList
  ].freeze

  # Associations
  belongs_to :user
  has_many :user_list_items, -> { order(:position) }, dependent: :destroy

  # Enums
  enum :view_mode, {default_view: 0, table_view: 1, grid_view: 2}, default: :default_view

  # Validations
  validates :name, presence: true
  validates :list_type, presence: true
  validate :list_type_immutable, on: :update
  validate :one_default_per_type_per_user

  # Scopes
  scope :public_lists, -> { where(public: true) }
  scope :owned_by, ->(user) { where(user: user) }

  # Class methods
  def self.default_subclasses
    DEFAULT_SUBCLASSES.map(&:constantize)
  end

  def self.default_list_types
    raise NotImplementedError, "#{name} must override .default_list_types"
  end

  def self.listable_class
    raise NotImplementedError, "#{name} must override .listable_class"
  end

  def self.default_list_name_for(list_type)
    raise NotImplementedError, "#{name} must override .default_list_name_for"
  end

  # Instance methods
  def default?
    list_type.to_s != "custom"
  end

  def reorder_items!(ordered_listable_ids)
    ordered_listable_ids = ordered_listable_ids.map(&:to_i)
    transaction do
      existing_ids = user_list_items.pluck(:listable_id)
      unless existing_ids.sort == ordered_listable_ids.sort
        raise ArgumentError, "ordered_listable_ids must exactly match the current set of items"
      end
      items_by_listable = user_list_items.index_by(&:listable_id)
      ordered_listable_ids.each_with_index do |listable_id, idx|
        items_by_listable.fetch(listable_id).update_column(:position, idx + 1)
      end
    end
  end

  private

  def list_type_immutable
    return unless list_type_changed?
    errors.add(:list_type, "cannot be changed after creation")
  end

  # STI scopes `self.class.where(...)` to this subclass via the `type` column automatically,
  # which is important because `list_type` integers are declared independently per subclass.
  def one_default_per_type_per_user
    return if list_type.blank? || user_id.blank?
    return if list_type.to_s == "custom"
    scope = self.class.where(user_id: user_id, list_type: list_type)
    scope = scope.where.not(id: id) if persisted?
    return unless scope.exists?
    errors.add(:list_type, "default list already exists for this user")
  end
end
