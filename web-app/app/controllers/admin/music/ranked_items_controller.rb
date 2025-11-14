class Admin::Music::RankedItemsController < Admin::Music::BaseController
  def index
    @ranking_configuration = RankingConfiguration.find(params[:ranking_configuration_id])
    @ranked_items = @ranking_configuration.ranked_items

    # Only eager-load artists association for album and song configurations
    # Artist configurations don't have an artists association (artists don't belong to artists)
    if @ranking_configuration.type.in?(["Music::Albums::RankingConfiguration", "Music::Songs::RankingConfiguration"])
      @ranked_items = @ranked_items.includes(item: :artists)
    end

    @ranked_items = @ranked_items.order(rank: :asc)

    @pagy, @ranked_items = pagy(@ranked_items, items: 25)

    render layout: false
  end
end
