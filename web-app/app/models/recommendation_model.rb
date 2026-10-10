# == Schema Information
#
# Table name: recommendation_models
#
#  id         :bigint           not null, primary key
#  domain     :string           not null
#  manifest   :jsonb            not null
#  state      :integer          default(0), not null
#  version    :string           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
# Indexes
#
#  index_recommendation_models_on_domain_and_state    (domain,state)
#  index_recommendation_models_on_domain_and_version  (domain,version) UNIQUE
#
# One trained collaborative model per domain and version (spec 2 §5). A load
# inserts under `loading`, then swaps to `active` in one transaction while the
# previous active row is retired, so the signal never reads a half-loaded
# model. The version is the export name the trainer read.
class RecommendationModel < ApplicationRecord
  has_many :recommendation_item_neighbors, dependent: :delete_all

  enum :state, {loading: 0, active: 1, retired: 2}

  validates :domain, :version, presence: true
  validates :version, uniqueness: {scope: :domain}

  def self.active_for(domain)
    active.find_by(domain: domain.to_s)
  end
end
