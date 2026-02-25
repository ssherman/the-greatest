class Games::ListsController < ApplicationController
  include Pagy::Method
  include Cacheable

  layout "games/application"

  before_action :load_ranking_configuration
  before_action :cache_for_index_page, only: [:index]
  before_action :cache_for_show_page, only: [:show]

  def self.ranking_configuration_class
    Games::RankingConfiguration
  end

  def index
    @ranked_lists = @ranking_configuration.ranked_lists
      .joins(:list)
      .where(lists: {type: "Games::List"})
      .includes(list: :list_items)
      .order(weight: :desc)
      .limit(50)
  end

  def show
    @list = Games::List.find(params[:id])
    @ranked_list = @ranking_configuration.ranked_lists.find_by(list: @list)

    list_items_query = @list.list_items.includes(
      listable: [
        :categories,
        :platforms,
        {game_companies: :company},
        {primary_image: {file_attachment: {blob: {variant_records: {image_attachment: :blob}}}}}
      ]
    ).order(Arel.sql("list_items.position ASC NULLS LAST"))
    @pagy, @pagy_list_items = pagy(list_items_query, limit: 100)
  end
end
