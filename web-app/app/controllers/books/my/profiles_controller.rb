class Books::My::ProfilesController < ApplicationController
  include Cacheable

  layout "books/application"

  before_action :prevent_caching
  before_action :require_signed_in!

  SETTINGS_PARAMS = [:public, :display_name, *Books::Profile::SECTIONS.map { |section| :"show_#{section}" }].freeze

  def show
    @profile = current_user.books_profile
    @profile_data = Services::Books::Profiles::Build.call(user: current_user, audience: :owner).data
  end

  # Never saves: a profile row exists only once the reader submits the form.
  def settings
    @profile = current_user.books_profile ||
      current_user.build_books_profile(display_name: current_user.display_name.presence)
  end

  def update_settings
    result = Services::Books::Profiles::SaveSettings.call(
      user: current_user,
      attributes: params.fetch(:books_profile, {}).permit(*SETTINGS_PARAMS)
    )
    @profile = result.data[:profile]

    if !result.data[:persisted]
      render :settings, status: :unprocessable_entity
    elsif result.data[:purge_confirmed] == false
      redirect_to books_my_profile_settings_path,
        alert: "Saved. Your profile is updated, but we could not confirm the cached copy was cleared. It will clear within 10 minutes."
    else
      redirect_to books_my_profile_settings_path, notice: "Profile settings saved."
    end
  end

  # What a visitor would see, whether or not the profile is public yet.
  def preview
    profile = current_user.books_profile
    return redirect_to(books_my_profile_settings_path) unless profile

    @profile_data = Services::Books::Profiles::Build.call(user: current_user, audience: :public, profile: profile).data
  end
end
