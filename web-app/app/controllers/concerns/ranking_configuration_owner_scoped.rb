# frozen_string_literal: true

# The owner-only half of /my/rankings: which registry entries serve this
# host, the owner-scoped lookup, and the entry for a loaded configuration.
# Named after SavedSearchDomainScoped, which does the same job for /searches.
#
# Every lookup is scoped through current_user.ranking_configurations, so a
# stranger's id -- shared or not -- is a 404, never a 403 that would confirm
# it exists. The type filter keeps a configuration from another domain off
# this host.
#
# Registry constants are root-anchored because the lists controller lives
# in the My::RankingConfigurations namespace, where a bare
# RankingConfigurations would resolve to that module.
module RankingConfigurationOwnerScoped
  extend ActiveSupport::Concern

  included do
    helper_method :current_entry
  end

  private

  def domain_entries
    @domain_entries ||= ::RankingConfigurations::Registry.for_domain(Current.domain)
  end

  # Before require_signed_in!, so a host with no entry 404s instead of
  # bouncing an anonymous visitor to a sign-in that would not have helped.
  def require_domain_support!
    raise ActiveRecord::RecordNotFound if domain_entries.empty?
  end

  def set_ranking_configuration(query = nil)
    id = params[:ranking_configuration_id] || params[:id]
    @ranking_configuration = current_user.ranking_configurations
      .where(type: domain_entries.map(&:ranking_configuration_class))
      .find(id)
    authorize @ranking_configuration, query, policy_class: RankingConfigurationPolicy
  end

  def current_entry
    @current_entry ||= ::RankingConfigurations::Registry.for_config(@ranking_configuration)
  end
end
