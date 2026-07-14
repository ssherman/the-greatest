class Admin::Music::RankingConfigurationsController < Admin::RankingConfigurationsController
  include Admin::DomainScopedAuth

  private

  def policy_class
    Music::RankingConfigurationPolicy
  end

  def domain_name
    "music"
  end
end
