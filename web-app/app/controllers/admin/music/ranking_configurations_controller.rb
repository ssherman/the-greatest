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

  def ranking_configuration_class
    raise NotImplementedError, "Subclass must implement ranking_configuration_class"
  end

  def ranking_configurations_path
    raise NotImplementedError, "Subclass must implement ranking_configurations_path"
  end

  def ranking_configuration_path(config)
    raise NotImplementedError, "Subclass must implement ranking_configuration_path"
  end

  def table_partial_path
    raise NotImplementedError, "Subclass must implement table_partial_path"
  end
end
