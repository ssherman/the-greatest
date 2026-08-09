# frozen_string_literal: true

# == Schema Information
#
# Table name: saved_searches
#
#  id               :bigint           not null, primary key
#  criteria         :jsonb            not null
#  description      :text
#  last_executed_at :datetime
#  name             :string
#  public           :boolean          default(FALSE), not null
#  result_count     :integer
#  type             :string           not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  user_id          :bigint           not null
#
# Indexes
#
#  index_saved_searches_on_public            (public) WHERE (public = true)
#  index_saved_searches_on_type_and_user_id  (type,user_id)
#  index_saved_searches_on_user_id           (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
class SavedSearch < ApplicationRecord
  belongs_to :user

  # Which STI subclass serves which host. Mirrors UserList::DOMAIN_SUBCLASSES.
  # A domain absent from this map has no saved searches, and the controller
  # 404s rather than rendering an empty page in the wrong layout.
  DOMAIN_SUBCLASSES = {"books" => "Books::SavedSearch"}.freeze

  def self.subclass_for(domain)
    DOMAIN_SUBCLASSES[domain.to_s]&.constantize
  end

  validates :criteria, presence: true

  scope :public_searches, -> { where(public: true) }
  scope :owned_by, ->(user) { where(user: user) }
  scope :by_last_executed, -> { order(Arel.sql("last_executed_at DESC NULLS LAST")) }
  scope :by_created, -> { order(created_at: :desc) }

  # Searches a viewer may read: their own, plus anyone's public ones. Kept as a
  # query rather than a policy check because Pundit's NotAuthorizedError rescue
  # redirects, which would confirm that a private search exists; falling out of
  # this scope 404s instead. Mirrors UserList.visible_to for the same reason.
  scope :visible_to, ->(user) { user ? public_searches.or(owned_by(user)) : public_searches }

  def self.criteria_class
    raise NotImplementedError, "#{name} must override .criteria_class"
  end

  def self.query_class
    raise NotImplementedError, "#{name} must override .query_class"
  end

  def self.ranking_configuration_class
    raise NotImplementedError, "#{name} must override .ranking_configuration_class"
  end

  # The user_list list_type that `hide_read` excludes: :read for books,
  # :played for games.
  def self.excluded_list_type
    raise NotImplementedError, "#{name} must override .excluded_list_type"
  end

  def display_name
    name.presence || "Search #{id}"
  end

  # The typed view of `criteria`, built through the subclass's declared
  # criteria_class. Memoized because summary reads several values from it and
  # increment 5's controller will hand the same object to the query layer.
  def criteria_object
    @criteria_object ||= self.class.criteria_class.new(criteria)
  end

  # The memo must not outlive the value it wraps -- increment 6's form assigns
  # criteria and re-renders on the same instance.
  def criteria=(value)
    @criteria_object = nil
    super
  end
end
