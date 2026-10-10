# == Schema Information
#
# Table name: recommendation_configs
#
#  id                    :bigint           not null, primary key
#  book_lengths          :integer          is an Array
#  exclude_locations     :boolean          default(FALSE)
#  excluded_category_ids :integer          is an Array
#  included_category_all :boolean          default(FALSE), not null
#  included_category_ids :integer          default([]), is an Array
#  published_year_end    :integer
#  published_year_start  :integer
#  ranked_limit          :integer
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  user_id               :bigint           not null
#
# Indexes
#
#  index_recommendation_configs_on_user_id  (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
module LegacyBooks
  class RecommendationConfig < Record
    self.table_name = "recommendation_configs"
  end
end
