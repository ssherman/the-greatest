class Admin::Games::DuplicateCandidatesController < Admin::DuplicateCandidatesBaseController
  private

  def domain = :games

  def route_prefix = "admin_games_"
end
