class Admin::Music::RankingConfigurationsController < Admin::RankingConfigurationsController
  include Admin::DomainScopedAuth

  layout "music/admin"

  private

  def policy_class
    Music::RankingConfigurationPolicy
  end

  def domain_name
    "music"
  end
end
