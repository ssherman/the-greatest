# == Schema Information
#
# Table name: penalties
#
#  id          :bigint           not null, primary key
#  description :text
#  dynamic     :boolean          default(FALSE), not null
#  global      :boolean          default(FALSE), not null
#  media_type  :integer          default("cross_media"), not null
#  name        :string           not null
#  type        :string           not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  user_id     :bigint
#
# Indexes
#
#  index_penalties_on_dynamic     (dynamic)
#  index_penalties_on_global      (global)
#  index_penalties_on_media_type  (media_type)
#  index_penalties_on_type        (type)
#  index_penalties_on_user_id     (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
module Games
  class Penalty < ::Penalty
    # Games-specific penalty logic can be added here

    # Example of a dynamic penalty for games
    def calculate_penalty_value(list, ranking_configuration)
      return super unless dynamic?

      # Example: Penalty based on AAA bias
      if name.include?("AAA")
        # Check if list has mostly AAA games
        aaa_games_count = list.list_items.joins(:listable)
          .where("games.budget_category = ?", "AAA")
          .count
        total_items = list.list_items.count

        if total_items > 0 && (aaa_games_count.to_f / total_items) > 0.8
          return penalty_applications.find_by(ranking_configuration: ranking_configuration)&.value || 15
        end
      end

      super
    end
  end
end
