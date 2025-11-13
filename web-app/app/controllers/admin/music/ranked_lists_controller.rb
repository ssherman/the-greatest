class Admin::Music::RankedListsController < Admin::Music::BaseController
  def index
    @ranking_configuration = RankingConfiguration.find(params[:ranking_configuration_id])
    @ranked_lists = @ranking_configuration.ranked_lists
      .includes(list: :submitted_by)
      .order(weight: :desc)

    @pagy, @ranked_lists = pagy(@ranked_lists, items: 25)

    render layout: false
  end
end
