# == Schema Information
#
# Table name: games_game_companies
#
#  id         :bigint           not null, primary key
#  developer  :boolean          default(FALSE), not null
#  publisher  :boolean          default(FALSE), not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  company_id :bigint           not null
#  game_id    :bigint           not null
#
# Indexes
#
#  index_games_game_companies_on_company_id        (company_id)
#  index_games_game_companies_on_developer         (developer)
#  index_games_game_companies_on_game_and_company  (game_id,company_id) UNIQUE
#  index_games_game_companies_on_game_id           (game_id)
#  index_games_game_companies_on_publisher         (publisher)
#
# Foreign Keys
#
#  fk_rails_...  (company_id => games_companies.id)
#  fk_rails_...  (game_id => games_games.id)
#
class Games::GameCompany < ApplicationRecord
  # Associations
  belongs_to :game, class_name: "Games::Game"
  belongs_to :company, class_name: "Games::Company"

  # Validations
  validates :game_id, uniqueness: {scope: :company_id}
  validate :at_least_one_role

  # Scopes
  scope :developers, -> { where(developer: true) }
  scope :publishers, -> { where(publisher: true) }

  private

  def at_least_one_role
    unless developer? || publisher?
      errors.add(:base, "must be either a developer or publisher (or both)")
    end
  end
end
