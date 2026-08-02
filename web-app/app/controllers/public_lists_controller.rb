class PublicListsController < ApplicationController
  include Pagy::Method
  include Cacheable
  include PathBasedPagination

  before_action :load_ranking_configuration
  before_action :apply_caching

  def self.lists_query_class
    raise NotImplementedError, "#{name} must define .lists_query_class"
  end

  def self.ranking_configuration_class
    raise NotImplementedError, "#{name} must define .ranking_configuration_class"
  end

  def index
    @sort = self.class.lists_query_class.normalize_sort(params[:sort])
    @query = params[:q].is_a?(String) ? params[:q].presence : nil
    @indexable = @query.blank?

    @pagy, @ranked_lists = pagy_path(
      self.class.lists_query_class.call(
        ranking_configuration: @ranking_configuration, sort: @sort, query: @query
      ),
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
