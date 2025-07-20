# == Schema Information
#
# Table name: penalties
#
#  id           :bigint           not null, primary key
#  description  :text
#  dynamic_type :integer
#  global       :boolean          default(FALSE), not null
#  media_type   :integer          default("cross_media"), not null
#  name         :string           not null
#  type         :string           not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  user_id      :bigint
#
# Indexes
#
#  index_penalties_on_global      (global)
#  index_penalties_on_media_type  (media_type)
#  index_penalties_on_type        (type)
#  index_penalties_on_user_id     (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
module Music
  class Penalty < ::Penalty
    # Music-specific penalty logic can be added here

    # Example of a dynamic penalty for music
    def calculate_penalty_value(list, ranking_configuration)
      return super unless dynamic?

      # TODO: Implement Music-specific dynamic penalty logic once Music models are complete
      # For now, return the static penalty value
      super
    end
  end
end
