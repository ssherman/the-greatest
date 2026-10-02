class Admin::Music::MatchDecisionsController < Admin::MatchDecisionsBaseController
  private

  def domain = :music

  def route_prefix = "admin_"
end
