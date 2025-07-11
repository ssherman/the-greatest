# == Schema Information
#
# Table name: penalty_applications
#
#  id                       :bigint           not null, primary key
#  value                    :integer          default(0), not null
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  penalty_id               :bigint           not null
#  ranking_configuration_id :bigint           not null
#
# Indexes
#
#  index_penalty_applications_on_penalty_and_config        (penalty_id,ranking_configuration_id) UNIQUE
#  index_penalty_applications_on_penalty_id                (penalty_id)
#  index_penalty_applications_on_ranking_configuration_id  (ranking_configuration_id)
#
# Foreign Keys
#
#  fk_rails_...  (penalty_id => penalties.id)
#  fk_rails_...  (ranking_configuration_id => ranking_configurations.id)
#
require "test_helper"

class PenaltyApplicationTest < ActiveSupport::TestCase
  # test "the truth" do
  #   assert true
  # end
end
