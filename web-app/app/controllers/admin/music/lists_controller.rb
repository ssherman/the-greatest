class Admin::Music::ListsController < Admin::Music::BaseController
  before_action :set_list, only: [:show, :edit, :update, :destroy]

  def index
    load_lists_for_index
  end

  def show
    @list = list_class
      .includes(:submitted_by, :penalties, list_items: {listable: listable_includes})
      .find(params[:id])
  end

  def new
    @list = list_class.new
  end

  def create
    @list = list_class.new(list_params)

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

  def load_lists_for_index
    sort_column = sortable_column(params[:sort])
    sort_direction = sortable_direction(params[:direction])

    @lists = list_class
      .includes(:submitted_by)
      .left_joins(:list_items)
      .select("#{list_class.table_name}.*, COUNT(DISTINCT list_items.id) as #{items_count_name}")
      .group("#{list_class.table_name}.id")
      .order("#{sort_column} #{sort_direction}")

    @pagy, @lists = pagy(@lists, items: 25)
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
