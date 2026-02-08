# == Schema Information
#
# Table name: games_game_platforms
#
#  id          :bigint           not null, primary key
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  game_id     :bigint           not null
#  platform_id :bigint           not null
#
# Indexes
#
#  index_games_game_platforms_on_game_and_platform  (game_id,platform_id) UNIQUE
#  index_games_game_platforms_on_game_id            (game_id)
#  index_games_game_platforms_on_platform_id        (platform_id)
#
# Foreign Keys
#
#  fk_rails_...  (game_id => games_games.id)
#  fk_rails_...  (platform_id => games_platforms.id)
#
class Games::GamePlatform < ApplicationRecord
  # Associations
  belongs_to :game, class_name: "Games::Game"
  belongs_to :platform, class_name: "Games::Platform"

  # Validations
  validates :game_id, uniqueness: {scope: :platform_id}
end
