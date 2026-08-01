class Games::ListsController < PublicListsController
  layout "games/application"

  def self.ranking_configuration_class
    Games::RankingConfiguration
  end

  def self.lists_query_class
    Games::ListsQuery
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
    @pagy, @pagy_list_items = pagy_path(list_items_query, limit: 100)
  end
end
