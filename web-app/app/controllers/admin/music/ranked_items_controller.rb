class Admin::Music::RankedItemsController < Admin::Music::BaseController
  def index
    @ranking_configuration = RankingConfiguration.find(params[:ranking_configuration_id])
    @ranked_items = @ranking_configuration.ranked_items
      .includes(item: :artists)
      .order(rank: :asc)

    @pagy, @ranked_items = pagy(@ranked_items, items: 25)

    render layout: false
  end
end
