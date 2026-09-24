class Admin::Games::MatchDecisionsController < Admin::MatchDecisionsBaseController
  private

  def domain = :games

  def route_prefix = "admin_games_"
end
