class Admin::RankedItemsController < Admin::BaseController
  include Admin::DomainScopedAuth

  def index
    @ranking_configuration = RankingConfiguration.find(params[:ranking_configuration_id])
    @ranked_items = @ranking_configuration.ranked_items

    includes = Admin::DomainRouting.ranking_configuration_config(@ranking_configuration)&.dig(:ranked_item_includes)
    @ranked_items = @ranked_items.includes(includes) if includes

    @ranked_items = @ranked_items.order(rank: :asc)

    @pagy, @ranked_items = pagy(@ranked_items, limit: 25)

    render layout: false
  end

  private

  def domain_for_auth
    domain_with_admin_for(RankingConfiguration.find_by(id: ranking_configuration_id_for_auth))
  end

  def access_denied_message(_domain)
    "Access denied."
  end

  def ranking_configuration_id_for_auth
    params[:ranking_configuration_id]
  end
end
