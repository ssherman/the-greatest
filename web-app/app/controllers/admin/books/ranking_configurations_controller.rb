class Admin::Books::RankingConfigurationsController < Admin::RankingConfigurationsController
  include Admin::DomainScopedAuth

  private

  def policy_class = ::Books::RankingConfigurationPolicy

  def domain_name = "books"

  def ranking_configuration_class = ::Books::RankingConfiguration

  def ranking_configurations_path(**opts) = admin_books_ranking_configurations_path(**opts)

  def ranking_configuration_path(config, **opts) = admin_books_ranking_configuration_path(config, **opts)

  def new_ranking_configuration_path = new_admin_books_ranking_configuration_path

  def edit_ranking_configuration_path(config) = edit_admin_books_ranking_configuration_path(config)

  def execute_action_ranking_configuration_path(config, **opts) = execute_action_admin_books_ranking_configuration_path(config, **opts)

  def index_action_ranking_configurations_path(**opts) = index_action_admin_books_ranking_configurations_path(**opts)
end
