# == Schema Information
#
# Table name: list_penalties
#
#  id         :bigint           not null, primary key
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  list_id    :bigint           not null
#  penalty_id :bigint           not null
#
# Indexes
#
#  index_list_penalties_on_list_and_penalty  (list_id,penalty_id) UNIQUE
#  index_list_penalties_on_list_id           (list_id)
#  index_list_penalties_on_penalty_id        (penalty_id)
#
# Foreign Keys
#
#  fk_rails_...  (list_id => lists.id)
#  fk_rails_...  (penalty_id => penalties.id)
#
require "test_helper"

class ListPenaltyTest < ActiveSupport::TestCase
  # test "the truth" do
  #   assert true
  # end
end
