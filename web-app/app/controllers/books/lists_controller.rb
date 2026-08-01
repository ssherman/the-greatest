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
    @query = params[:q].presence
    @indexable = @query.blank?

    @pagy, @ranked_lists = pagy_path(
      Books::ListsQuery.call(ranking_configuration: @ranking_configuration, sort: @sort, query: @query),
      limit: 50
    )

    @item_counts = ListItem.where(list_id: @ranked_lists.map(&:list_id)).group(:list_id).count
  end

  private

  def apply_caching
    return prevent_caching if params[:q].present?

    (action_name == "show") ? cache_for_show_page : cache_for_index_page
  end
end
