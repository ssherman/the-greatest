module RankingConfigurationDomainAuth
  extend ActiveSupport::Concern

  private

  def authenticate_admin!
    return if current_user&.admin? || current_user&.editor?

    domain = domain_for_ranking_configuration
    unless domain && current_user&.can_access_domain?(domain)
      redirect_to domain_root_path, alert: "Access denied."
    end
  end

  def domain_for_ranking_configuration
    config = RankingConfiguration.find_by(id: ranking_configuration_id_for_auth)
    return nil unless config

    case config.type
    when /^Games::/ then "games"
    when /^Music::/ then "music"
    end
  end

  def ranking_configuration_id_for_auth
    params[:ranking_configuration_id]
  end
end
