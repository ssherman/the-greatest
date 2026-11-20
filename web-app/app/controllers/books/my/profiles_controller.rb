class Books::My::ProfilesController < ApplicationController
  include Cacheable

  layout "books/application"

  before_action :prevent_caching
  before_action :require_signed_in!

  def show
    @profile_data = Services::Books::Profiles::Build.call(user: current_user, audience: :owner).data
  end
end
