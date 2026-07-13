class Admin::RankedItemsController < Admin::BaseController
  include Admin::DomainScopedAuth

  def index
    @ranking_configuration = RankingConfiguration.find(params[:ranking_configuration_id])
    @ranked_items = @ranking_configuration.ranked_items

    # Eager-load associations based on configuration type
    case @ranking_configuration.type
    when "Music::Albums::RankingConfiguration", "Music::Songs::RankingConfiguration"
      @ranked_items = @ranked_items.includes(item: :artists)
    when "Games::RankingConfiguration"
      @ranked_items = @ranked_items.includes(item: :companies)
    end

    @ranked_items = @ranked_items.order(rank: :asc)

    @pagy, @ranked_items = pagy(@ranked_items, limit: 25)

    render layout: false
  end

  private

  def domain_for_auth
    config = RankingConfiguration.find_by(id: ranking_configuration_id_for_auth)
    Admin::DomainRouting.domain_for(config)&.to_s if config
  end

  def access_denied_message(_domain)
    "Access denied."
  end

  def ranking_configuration_id_for_auth
    params[:ranking_configuration_id]
  end
end
