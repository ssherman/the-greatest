# The lists page of a user-owned ranking configuration: search-and-add,
# the diff against the official ranking, and the paginated list of what is
# in it. Every mutation answers a Turbo Stream request by re-rendering the
# rc_lists frame (the Admin::RankedListsController shape) and a plain
# request with a redirect back here.
class My::RankingConfigurations::ListsController < ApplicationController
  include Pagy::Method
  include Cacheable
  include DomainLayout
  include RankingConfigurationOwnerScoped

  PER_PAGE = 50
  SEARCH_LIMIT = 10

  layout :resolve_layout

  before_action :prevent_caching
  before_action :require_domain_support!
  before_action :require_signed_in!
  before_action { set_ranking_configuration(:manage_lists?) }

  def index
    load_frame
  end

  # JSON for the picker: active lists of this domain's type matching the
  # query, minus the ones already in the configuration.
  def search
    query = params[:q].is_a?(String) ? params[:q].strip : ""
    return render json: [] if query.blank?

    lists = current_entry.list_class.constantize
      .where(status: :active)
      .search_text(query)
      .where.not(id: @ranking_configuration.ranked_lists.select(:list_id))
      .order(:name)
      .limit(SEARCH_LIMIT)

    render json: lists.map { |list| {value: list.id, text: list.name_with_source} }
  end

  def create
    result = Services::RankingConfigurations::AddLists.call(
      config: @ranking_configuration, entry: current_entry, list_ids: params[:list_ids]
    )
    @frame_notice = "Added #{helpers.pluralize(result.data[:added], "list")}. Refresh weights and rankings to apply."
    respond_with_frame
  end

  def add_missing
    missing_ids = ::RankingConfigurations::MissingListsQuery.call(
      config: @ranking_configuration, entry: current_entry
    ).pluck(:list_id)
    result = Services::RankingConfigurations::AddLists.call(
      config: @ranking_configuration, entry: current_entry, list_ids: missing_ids
    )
    @frame_notice = "Added #{helpers.pluralize(result.data[:added], "list")} from the official rankings. Refresh weights and rankings to apply."
    respond_with_frame
  end

  def destroy
    ranked_list = @ranking_configuration.ranked_lists.find_by!(list_id: params[:list_id])
    name = ranked_list.list.name
    ranked_list.destroy
    @ranking_configuration.update!(needs_refresh: true)
    @frame_notice = "Removed #{name}. Refresh weights and rankings to apply."
    respond_with_frame
  end

  private

  def load_frame
    @missing = ::RankingConfigurations::MissingListsQuery.call(config: @ranking_configuration, entry: current_entry).to_a
    scope = @ranking_configuration.ranked_lists
      .includes(:list)
      .order(Arel.sql("ranked_lists.weight DESC NULLS LAST, ranked_lists.id ASC"))
    @pagy, @ranked_lists = pagy(scope, limit: PER_PAGE, page: clamped_page(scope))
  end

  # After a removal the requested page can lie past the end; clamp rather
  # than let Pagy raise or render an empty page.
  def clamped_page(scope)
    last = [(scope.count - 1) / PER_PAGE + 1, 1].max
    params[:page].to_i.clamp(1, last)
  end

  def respond_with_frame
    load_frame
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace("rc_lists", partial: "my/ranking_configurations/lists/frame")
      end
      format.html do
        redirect_to my_ranking_configuration_lists_path(@ranking_configuration, page: @pagy.page), status: :see_other
      end
    end
  end
end
