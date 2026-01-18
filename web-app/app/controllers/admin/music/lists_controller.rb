class Admin::Music::ListsController < Admin::Music::BaseController
  before_action :set_list, only: [:show, :edit, :update, :destroy]
  before_action :authorize_list, only: [:show, :edit, :update, :destroy]

  def index
    authorize list_class, policy_class: Music::ListPolicy
    load_lists_for_index
    @selected_status = params[:status].presence || "all"
    @search_query = params[:q].presence
  end

  def show
    @list = list_class
      .includes(:submitted_by, list_penalties: :penalty, list_items: {listable: listable_includes})
      .find(params[:id])
  end

  def new
    @list = list_class.new
    authorize @list, policy_class: Music::ListPolicy
  end

  def create
    @list = list_class.new(list_params)
    authorize @list, policy_class: Music::ListPolicy

    if @list.save
      redirect_to list_path(@list), notice: "Album list created successfully."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @list.update(list_params)
      redirect_to list_path(@list), notice: "Album list updated successfully."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @list.destroy!
    redirect_to lists_path, notice: "Album list deleted successfully."
  end

  private

  def set_list
    @list = list_class.find(params[:id])
  end

  def authorize_list
    authorize @list, policy_class: Music::ListPolicy
  end

  def load_lists_for_index
    sort_column = sortable_column(params[:sort])
    sort_direction = sortable_direction(params[:direction])

    @lists = list_class
      .includes(:submitted_by)
      .left_joins(:list_items)
      .then { |scope| apply_status_filter(scope) }
      .then { |scope| apply_search_filter(scope) }
      .select("#{list_class.table_name}.*, COUNT(DISTINCT list_items.id) as #{items_count_name}")
      .group("#{list_class.table_name}.id")
      .order("#{sort_column} #{sort_direction}")

    @pagy, @lists = pagy(@lists, items: 25)
  end

  def apply_status_filter(scope)
    return scope if params[:status].blank? || params[:status] == "all"

    status_value = params[:status].to_s.downcase
    return scope unless List.statuses.key?(status_value)

    scope.where(status: status_value)
  end

  def apply_search_filter(scope)
    return scope if params[:q].blank?
    scope.search_by_name(params[:q])
  end

  def sortable_column(column)
    allowed_columns = {
      "id" => "lists.id",
      "name" => "lists.name",
      "year_published" => "lists.year_published",
      "created_at" => "lists.created_at"
    }

    allowed_columns.fetch(column.to_s, "lists.name")
  end

  def sortable_direction(direction)
    (direction.to_s.downcase == "desc") ? "DESC" : "ASC"
  end

  def list_params
    params.require(param_key).permit(
      :name,
      :description,
      :source,
      :source_country_origin,
      :url,
      :year_published,
      :number_of_voters,
      :estimated_quality,
      :status,
      :high_quality_source,
      :category_specific,
      :location_specific,
      :yearly_award,
      :voter_count_estimated,
      :voter_count_unknown,
      :voter_names_unknown,
      :creator_specific,
      :num_years_covered,
      :musicbrainz_series_id,
      :items_json,
      :raw_html,
      :simplified_html,
      :formatted_text
    )
  end

  protected

  def list_class
    raise NotImplementedError, "Subclass must implement list_class"
  end

  def lists_path
    raise NotImplementedError, "Subclass must implement lists_path"
  end

  def list_path(list)
    raise NotImplementedError, "Subclass must implement list_path"
  end

  def new_list_path
    raise NotImplementedError, "Subclass must implement new_list_path"
  end

  def edit_list_path(list)
    raise NotImplementedError, "Subclass must implement edit_list_path"
  end

  def param_key
    raise NotImplementedError, "Subclass must implement param_key"
  end

  def items_count_name
    raise NotImplementedError, "Subclass must implement items_count_name"
  end

  def listable_includes
    raise NotImplementedError, "Subclass must implement listable_includes"
  end
end
