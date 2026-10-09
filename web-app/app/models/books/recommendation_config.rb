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
#  index_recommendation_configs_on_user_id           (user_id)
#  index_recommendation_configs_on_user_id_and_type  (user_id,type) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
module Books
  class RecommendationConfig < ::RecommendationConfig
    def self.criteria_class
      ::Books::RecommendationCriteria
    end

    def self.criteria_params_class
      ::Books::RecommendationCriteriaParams
    end
  end
end
