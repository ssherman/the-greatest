# == Schema Information
#
# Table name: recommendation_configs
#
#  id         :bigint           not null, primary key
#  criteria   :jsonb            not null
#  type       :string           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  user_id    :bigint           not null
#
# Indexes
#
#  index_recommendation_configs_on_user_id_and_type  (user_id,type) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
# One row per user per domain: the preferences the recommendation engine applies
# as hard constraints (spec §4). STI mirrors SavedSearch: the host picks the
# subclass, the subclass names its criteria class.
class RecommendationConfig < ApplicationRecord
  belongs_to :user

  DOMAIN_SUBCLASSES = {"books" => "Books::RecommendationConfig"}.freeze

  def self.subclass_for(domain)
    DOMAIN_SUBCLASSES[domain.to_s]&.constantize
  end

  validates :user_id, uniqueness: {scope: :type}

  def self.criteria_class
    raise NotImplementedError, "#{name} must override .criteria_class"
  end

  # Find-or-initialize, never find-or-create: a GET must not write a row.
  def self.for_user(user)
    find_or_initialize_by(user: user)
  end

  def criteria_object
    @criteria_object ||= self.class.criteria_class.new(criteria)
  end

  def criteria=(value)
    @criteria_object = nil
    super
  end
end
