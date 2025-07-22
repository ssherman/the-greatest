# == Schema Information
#
# Table name: penalties
#
#  id           :bigint           not null, primary key
#  description  :text
#  dynamic_type :integer
#  name         :string           not null
#  type         :string           not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  user_id      :bigint
#
# Indexes
#
#  index_penalties_on_type     (type)
#  index_penalties_on_user_id  (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
module Books
  class Penalty < ::Penalty
    # Books-specific penalty logic can be added here
  end
end
