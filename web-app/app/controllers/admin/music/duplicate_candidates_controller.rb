class Admin::Music::DuplicateCandidatesController < Admin::DuplicateCandidatesBaseController
  private

  def domain = :music

  def route_prefix = "admin_"
end
