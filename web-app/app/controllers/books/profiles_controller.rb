# The public reader profile. Identical for every viewer, owner and admin
# included, so it can be cached at the edge: it only ever shows what the
# profile's switches allow anyone to see.
class Books::ProfilesController < ApplicationController
  include Cacheable

  layout "books/application"

  before_action :set_profile

  def show
    # @indexable stays unset, which the layout reads as noindex.
    @profile_data = Services::Books::Profiles::Build.call(
      user: @profile.user, audience: :public, profile: @profile
    ).data
  end

  private

  # A private profile is a 404 for everyone, so the URL reveals nothing about
  # whether the account exists or has a profile.
  def set_profile
    @profile = Books::Profile.includes(:user).find_by(id: params[:id])
    if @profile&.public?
      cache_at_edge_only(10.minutes)
    else
      prevent_caching
      raise ActiveRecord::RecordNotFound
    end
  end
end
