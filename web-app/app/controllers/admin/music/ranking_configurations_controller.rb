class Admin::Music::RankingConfigurationsController < Admin::RankingConfigurationsController
  layout "music/admin"

  private

  # Override authenticate_admin! to allow music domain access
  def authenticate_admin!
    return if current_user&.admin? || current_user&.editor?

    unless current_user&.can_access_domain?("music")
      redirect_to domain_root_path, alert: "Access denied. You need permission for music admin."
    end
  end

  def policy_class
    Music::RankingConfigurationPolicy
  end

  def domain_name
    "music"
  end
end
