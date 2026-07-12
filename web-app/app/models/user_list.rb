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

  # Maps a request domain to the UserList STI subclasses that live on it. Music
  # has two listables (albums + songs); games/movies have one each. Shared by
  # MyListsController, UserListStateController, and UserListsController so the
  # domain→subclass mapping can never drift between them. Books::UserList exists
  # (it's just not wired here) — it's deliberately excluded pending UI work; see
  # docs/features/user-lists.md ("What's Not Yet Implemented").
  DOMAIN_SUBCLASSES = {
    "music" => %w[Music::Albums::UserList Music::Songs::UserList],
    "games" => %w[Games::UserList],
    "movies" => %w[Movies::UserList]
  }.freeze

  # Associations
  belongs_to :user
  # inverse_of is set explicitly because the order scope disables Rails' automatic
  # inverse detection; without it, item.user_list would re-query (N+1) in views.
  has_many :user_list_items, -> { order(:position) }, dependent: :destroy, inverse_of: :user_list

  # Enums
  enum :view_mode, {default_view: 0, table_view: 1, grid_view: 2}, default: :default_view

  # Validations
  validates :name, presence: true
  validates :list_type, presence: true
  validate :list_type_immutable, on: :update
  validate :one_default_per_type_per_user

  # Callbacks
  after_commit :touch_user, on: [:create, :update, :destroy]

  # Scopes
  scope :public_lists, -> { where(public: true) }
  scope :owned_by, ->(user) { where(user: user) }

  # Class methods
  def self.default_subclasses
    DEFAULT_SUBCLASSES.map(&:constantize)
  end

  # Resolves the request domain (a Symbol app-wide; hence .to_s) to its live
  # UserList subclasses. Returns [] for unknown/unsupported domains (e.g. books).
  def self.subclasses_for(domain)
    (DOMAIN_SUBCLASSES[domain.to_s] || []).map(&:constantize)
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

  # Maps non-:custom list_type values to a Lucide icon name. Subclasses override
  # to declare per-type icons; :custom must never appear here (custom lists collapse
  # into a +N pill in the UI). Default to {} so subclasses without an override are inert.
  def self.list_type_icons
    {}
  end

  # The list_type values (symbols) for which a per-item completion date is
  # meaningful (e.g. :listened, :watched). Base returns []; subclasses override.
  # Phase A uses this only to decide whether completed_on is *displayed*; the
  # inline editor is Phase B.
  def self.completed_on_list_types
    []
  end

  # The RankingConfiguration STI subclass used to sort a list "by ranking".
  # Base returns nil (no ranking sort available); subclasses that support it override.
  def self.ranking_configuration_class
    nil
  end

  # Associations to eager-load on each listable when rendering the show page, so
  # the item views stay N+1-free. Base returns []; subclasses declare their own.
  def self.listable_display_includes
    []
  end

  # Instance methods
  def default?
    list_type.to_s != "custom"
  end

  # True when this list's list_type supports a completion date.
  def completed_on_enabled?
    self.class.completed_on_list_types.include?(list_type.to_sym)
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

  def touch_user
    return if user.nil? || user.destroyed? || user.new_record?
    user.touch
  end

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
