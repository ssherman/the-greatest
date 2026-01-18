class Music::Albums::ListsController < ApplicationController
  include Pagy::Method
  include Cacheable

  layout "music/application"

  before_action :load_ranking_configuration
  before_action :cache_for_index_page, only: [:index]
  before_action :cache_for_show_page, only: [:show]

  def self.ranking_configuration_class
    Music::Albums::RankingConfiguration
  end

  def index
    sort_order = (params[:sort] == "created_at") ? {"lists.created_at": :desc} : {weight: :desc}

    ranked_lists_query = @ranking_configuration.ranked_lists
      .joins(:list)
      .where(lists: {type: "Music::Albums::List"})
      .includes(list: :list_items)
      .order(sort_order)

    @pagy, @ranked_lists = pagy(ranked_lists_query, limit: 25)
  end

  def show
    @list = Music::Albums::List.find(params[:id])
    @ranked_list = @ranking_configuration.ranked_lists.find_by(list: @list)

    # Paginate list items with eager loading
    list_items_query = @list.list_items.includes(
      listable: [
        :artists,
        :categories,
        {primary_image: {file_attachment: {blob: {variant_records: {image_attachment: :blob}}}}}
      ]
    ).order(:position)
    @pagy, @pagy_list_items = pagy(list_items_query, limit: 100)
  end
end
