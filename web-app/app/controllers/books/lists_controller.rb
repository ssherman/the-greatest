class Books::ListsController < ApplicationController
  include Pagy::Method
  include Cacheable
  include PathBasedPagination

  layout "books/application"

  before_action :load_ranking_configuration
  before_action :apply_caching

  def self.ranking_configuration_class
    Books::RankingConfiguration
  end

  def index
    @sort = Books::ListsQuery::SORTS.include?(params[:sort].to_s) ? params[:sort].to_s : "weight"
    @query = params[:q].is_a?(String) ? params[:q].presence : nil
    @indexable = @query.blank?

    @pagy, @ranked_lists = pagy_path(
      Books::ListsQuery.call(ranking_configuration: @ranking_configuration, sort: @sort, query: @query),
      limit: 50
    )

    @item_counts = ListItem.where(list_id: @ranked_lists.map(&:list_id)).group(:list_id).count
  end

  def show
    @list = Books::List.where(status: :active).find_by!(id: params[:id])
    @ranked_list = @ranking_configuration.ranked_lists.find_by(list: @list)
    @indexable = @ranked_list.present?

    @pagy, @list_items = pagy_path(
      @list.list_items
        .includes(listable: [{book_authors: :author}, {primary_image: {file_attachment: :blob}}])
        .order(Arel.sql("list_items.position ASC NULLS LAST, list_items.id ASC")),
      limit: 100
    )

    book_ids = @list_items.filter_map { |item| item.listable_id if item.listable_type == "Books::Book" }
    @ranks = RankedItem.where(
      ranking_configuration: @ranking_configuration, item_type: "Books::Book", item_id: book_ids
    ).pluck(:item_id, :rank).to_h
  end

  private

  def apply_caching
    return prevent_caching if params[:q].present?

    (action_name == "show") ? cache_for_show_page : cache_for_index_page
  end
end
